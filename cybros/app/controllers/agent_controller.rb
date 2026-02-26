class AgentController < ApplicationController
  layout "agent"

  before_action :require_authentication
  before_action :load_sidebar_conversations

  private

    def load_sidebar_conversations
      before = params[:sidebar_before].to_s.presence
      if before.present? && !AgentCore::Utils.uuid_like?(before)
        before = nil
      end

      page_size = 50
      scope = Current.user.conversations.order(id: :desc)
      scope = scope.where("id < ?", before) if before.present?

      rows = scope.limit(page_size + 1).to_a
      @sidebar_has_more = rows.size > page_size
      @sidebar_conversations = rows.first(page_size)
      @sidebar_before_cursor = @sidebar_conversations.last&.id&.to_s
    end
end
