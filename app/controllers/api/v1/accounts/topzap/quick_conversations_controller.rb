class Api::V1::Accounts::Topzap::QuickConversationsController < Api::V1::Accounts::BaseController
  include ConversationAssignmentLimitConcern

  rescue_from CustomExceptions::QuickConversationError, with: :render_error_response

  def create
    inbox = Current.account.inboxes.find(params.require(:inbox_id))
    authorize inbox, :show?
    @conversation = ::Topzap::QuickConversationService.new(
      inbox: inbox, user: Current.user, params: quick_params
    ).perform
    render 'api/v1/accounts/conversations/create', status: :created
  end

  private

  def quick_params
    params.permit(:phone_number, :name, :send_csat, :content,
                  template_params: [:name, :language, :namespace, :category, :content_mode, { processed_params: {} }])
  end
end
