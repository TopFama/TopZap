# Non-admin users can only pick unassigned conversations in the "Não atendido" tab order (oldest last activity first)
class Conversations::QueueOrderService
  def initialize(account:, actor:, conversations:)
    @account = account
    @actor = actor
    @conversations = conversations.to_a
  end

  def validate!
    return unless applies?

    oldest_skipped = skipped_queue.order(:last_activity_at, :id).first
    return if oldest_skipped.blank?

    raise CustomExceptions::ConversationAssignmentNotAllowed,
          { message: I18n.t('errors.conversations.assignment.oldest_first', display_id: oldest_skipped.display_id) }
  end

  private

  attr_reader :account, :actor, :conversations

  # Agent bots assigning through the API aren't picking from the queue
  def applies?
    actor.is_a?(User) && !account.account_users.find_by!(user_id: actor.id).administrator? && picked.any?
  end

  def picked
    @picked ||= conversations.select { |conversation| conversation.open? && conversation.assignee_id.nil? && conversation.assignee_agent_bot_id.nil? }
  end

  def skipped_queue
    scope = account.conversations.open.unassigned.where.not(id: picked.map(&:id))
                   .where('conversations.last_activity_at < ?', picked.map(&:last_activity_at).max)
    Conversations::PermissionFilterService.new(scope, actor, account).perform
  end
end
