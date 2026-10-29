# Enforces manual assignment rules for agents:
# - an agent can't hold more open conversations than their account user's max_open_conversations
# - non-admin users can only pick unassigned conversations in the "Não atendido" tab order (oldest last activity first)
class Conversations::AssignmentRulesService
  def initialize(account:, actor:, assignee:, conversations:)
    @account = account
    @actor = actor
    @assignee = assignee
    @conversations = conversations.to_a
  end

  def validate!
    validate_open_conversations_limit!
    validate_queue_order!
  end

  private

  attr_reader :account, :actor, :assignee, :conversations

  def validate_open_conversations_limit!
    limit = account.account_users.find_by!(user_id: assignee.id).max_open_conversations
    return if limit.blank?

    incoming = conversations.count { |conversation| conversation.assignee_id != assignee.id && conversation.open? }
    return if incoming.zero?
    return if account.conversations.open.where(assignee_id: assignee.id).count + incoming <= limit

    raise_not_allowed(I18n.t('errors.conversations.assignment.limit_reached', agent_name: assignee.available_name, limit: limit))
  end

  def validate_queue_order!
    return if account.account_users.find_by!(user_id: actor.id).administrator?

    picked = conversations.select { |conversation| conversation.open? && conversation.assignee_id.nil? && conversation.assignee_agent_bot_id.nil? }
    return if picked.empty?

    skipped = unassigned_queue.where.not(id: picked.map(&:id))
                              .where('conversations.last_activity_at < ?', picked.map(&:last_activity_at).max)
    oldest_skipped = skipped.order(:last_activity_at, :id).first
    return if oldest_skipped.blank?

    raise_not_allowed(I18n.t('errors.conversations.assignment.oldest_first', display_id: oldest_skipped.display_id))
  end

  def unassigned_queue
    scope = account.conversations.open.unassigned
    Conversations::PermissionFilterService.new(scope, actor, account).perform
  end

  def raise_not_allowed(message)
    raise CustomExceptions::Conversation::AssignmentNotAllowed, { message: message }
  end
end
