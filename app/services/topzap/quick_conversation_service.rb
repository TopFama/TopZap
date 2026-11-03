class Topzap::QuickConversationService
  pattr_initialize [:inbox!, :user!, :params!]

  def perform
    validate_request!
    Conversations::AssignmentRulesService.new(account: inbox.account, assignee: user).enforce! do
      # Serialize contact lookup/creation for this account without changing existing contact names.
      inbox.account.with_lock do
        contact, contact_inbox = resolve_contact_and_inbox
        conversation = create_conversation(contact, contact_inbox)
        create_message(conversation)
        tag_quick_csat_conversation!(conversation) if params[:send_csat]
        conversation
      end
    end
  end

  private

  def phone_number
    params[:phone_number]
  end

  def validate_request!
    fail_with(:invalid_channel) unless inbox.whatsapp? && inbox.channel.provider == 'whatsapp_cloud'
    fail_with(:invalid_phone) unless phone_number.is_a?(String) && phone_number.match?(/\A\+55[1-9][0-9]{9,10}\z/)
    fail_with(:name_required) unless params[:name].is_a?(String) && params[:name].strip.present?
    fail_with(:invalid_csat) unless [true, false].include?(params[:send_csat])
    template = params[:send_csat] ? inbox.csat_config&.dig('template') : params[:template_params]
    fail_with(:template_required) unless CsatSurveyService.approved_whatsapp_template?(inbox, template)
  end

  def resolve_contact_and_inbox
    clean_number = phone_number.delete('+')
    candidates = phone_number_candidates(clean_number)

    # 1. Prioritize existing ContactInbox in this inbox matching any candidate (exact match first)
    contact_inbox = candidates.lazy.filter_map do |candidate|
      inbox.contact_inboxes.find_by(source_id: candidate)
    end.first

    return [contact_inbox.contact, contact_inbox] if contact_inbox.present?

    # 2. Prioritize existing Contact in this account matching any candidate (exact match first)
    contact = candidates.lazy.filter_map do |candidate|
      inbox.account.contacts.find_by(phone_number: "+#{candidate}")
    end.first

    # 3. If no existing contact found, create new contact with provided name
    contact ||= inbox.account.contacts.create!(
      name: params[:name].strip,
      phone_number: phone_number
    )

    # 4. Build or retrieve ContactInbox for this contact and inbox
    contact_inbox = ContactInboxBuilder.new(
      contact: contact,
      inbox: inbox,
      source_id: clean_number
    ).perform

    [contact, contact_inbox]
  end

  def phone_number_candidates(clean_number)
    Whatsapp::PhoneNumberNormalizationService.new(inbox).phone_number_candidates(clean_number)
  end

  def create_conversation(contact, contact_inbox)
    conversation = inbox.conversations.build(
      account: inbox.account,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :open,
      assignee: user
    )

    # Prevent bot from overriding status to pending in before_create,
    # while respecting resolved status if contact is blocked.
    def conversation.determine_conversation_status
      self.status = :resolved and return if contact.blocked?

      self.status = :open
    end

    # Prevent AutoAssignment callbacks from reassigning away from current_user
    # (e.g. when an admin is authorized to access the inbox but is not an InboxMember).
    def conversation.run_auto_assignment
      nil
    end

    def conversation.run_legacy_auto_assignment
      nil
    end

    conversation.save!

    desired_status = contact.blocked? ? :resolved : :open
    if conversation.status.to_sym != desired_status || conversation.assignee_id != user.id
      conversation.update!(status: desired_status, assignee: user)
    end

    conversation
  end

  def create_message(conversation)
    if params[:send_csat]
      CsatSurveyService.new(conversation: conversation).build_whatsapp_template_survey.save!
    else
      Messages::MessageBuilder.new(user, conversation, { content: params[:content], message_type: 'outgoing',
                                                       template_params: params[:template_params] }).perform
    end
  end

  def tag_quick_csat_conversation!(conversation)
    ensure_quick_csat_label!
    conversation.add_labels([CsatSurveyService::QUICK_CSAT_LABEL])
    ensure_inbox_survey_rule_tag!
  end

  def ensure_quick_csat_label!
    inbox.account.labels.find_or_create_by!(title: CsatSurveyService::QUICK_CSAT_LABEL) do |record|
      record.description = 'CSAT enviado na abertura rápida — não reenviar ao resolver'
      record.show_on_sidebar = true
      record.color = '#1f93ff'
    end
  rescue ActiveRecord::RecordNotUnique
    inbox.account.labels.find_by!(title: CsatSurveyService::QUICK_CSAT_LABEL)
  end

  def ensure_inbox_survey_rule_tag!
    return unless inbox.csat_survey_enabled?

    current_config = (inbox.csat_config || {}).deep_dup
    rules = current_config['survey_rules']

    if rules.blank?
      current_config['survey_rules'] = {
        'operator' => 'does_not_contain',
        'values' => [CsatSurveyService::QUICK_CSAT_LABEL]
      }
    elsif rules['operator'] == 'does_not_contain' || (rules['operator'].blank? && rules['values'].blank?)
      current_config['survey_rules']['operator'] ||= 'does_not_contain'
      current_values = Array(current_config['survey_rules']['values'])
      unless current_values.include?(CsatSurveyService::QUICK_CSAT_LABEL)
        current_config['survey_rules']['values'] = current_values + [CsatSurveyService::QUICK_CSAT_LABEL]
      end
    else
      return
    end

    inbox.update!(csat_config: current_config) if current_config != inbox.csat_config
  end

  def fail_with(reason)
    raise CustomExceptions::QuickConversationError, { reason: reason }
  end
end
