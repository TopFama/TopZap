class Topzap::QuickConversationService
  pattr_initialize [:inbox!, :user!, :params!]

  def perform
    validate_request!
    Conversations::AssignmentRulesService.new(account: inbox.account, assignee: user).enforce! do
      # Serialize contact lookup/creation for this account without changing existing contact names.
      inbox.account.with_lock do
        contact = inbox.account.contacts.find_or_create_by!(phone_number: phone_number) { |record| record.name = params[:name].strip }
        contact_inbox = ContactInboxBuilder.new(contact: contact, inbox: inbox, source_id: phone_number.delete('+')).perform
        conversation = inbox.conversations.create!(account: inbox.account, contact: contact, contact_inbox: contact_inbox,
                                                 status: :open, assignee: user)
        create_message(conversation)
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

  def create_message(conversation)
    if params[:send_csat]
      CsatSurveyService.new(conversation: conversation).build_whatsapp_template_survey.save!
    else
      Messages::MessageBuilder.new(user, conversation, { content: params[:content], message_type: 'outgoing',
                                                       template_params: params[:template_params] }).perform
    end
  end

  def fail_with(reason)
    raise CustomExceptions::QuickConversationError, { reason: reason }
  end
end
