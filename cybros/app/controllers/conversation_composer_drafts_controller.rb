class ConversationComposerDraftsController < AuthenticatedController
  rescue_from ArgumentError, AgentCore::ValidationError, Cybros::Error do |e|
    render json: { ok: false, error: e.class.name, message: e.message }, status: :unprocessable_entity
  end

  before_action :set_conversation

  def update
    @conversation.update_composer_draft!(**composer_draft_attributes)
    head :no_content
  end

  private

    def set_conversation
      id = params[:conversation_id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(id)

      @conversation = Current.user.conversations.find_by(id: id)
      raise ActiveRecord::RecordNotFound if @conversation.nil?
    end

    def composer_draft_attributes
      params.fetch(:composer_draft, {}).permit(:content, :model_ref, :permission_mode, :updated_at).to_h.symbolize_keys
    end
end
