class SidebarConversationsController < ApplicationController
  before_action :require_authentication

  def index
    before = params[:before].to_s.presence
    unless before.present? && AgentCore::Utils.uuid_like?(before)
      head :bad_request
      return
    end

    page_size = 50
    scope = Current.user.conversations.order(id: :desc)
    scope = scope.where("id < ?", before)

    rows = scope.limit(page_size + 1).to_a
    has_more = rows.size > page_size
    @conversations = rows.first(page_size)
    before_cursor = @conversations.last&.id&.to_s

    if has_more && before_cursor.present?
      response.set_header("X-Next-Page", sidebar_conversations_path(before: before_cursor))
    end

    render layout: false
  end
end
