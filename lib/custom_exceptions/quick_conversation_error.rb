class CustomExceptions::QuickConversationError < CustomExceptions::Base
  def message
    I18n.t("topzap.quick_conversations.#{@data[:reason]}")
  end

  def http_status
    :unprocessable_entity
  end
end
