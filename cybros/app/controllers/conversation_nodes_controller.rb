class ConversationNodesController < ApplicationController
  before_action :require_authentication
  before_action :set_conversation
  before_action :set_node_id

  rescue_from ArgumentError, DAG::ValidationError, DAG::OperationNotAllowedError, Cybros::Error do |e|
    respond_to do |format|
      format.turbo_stream { render plain: e.message, status: :unprocessable_entity }
      format.html { render plain: e.message, status: :unprocessable_entity }
      format.json { render json: { ok: false, error: e.class.name, message: e.message }, status: :unprocessable_entity }
    end
  end

  def exclude
    @conversation.exclude_node!(node_id: @node_id)
    redirect_to conversation_path(@conversation)
  end

  def include
    @conversation.include_node!(node_id: @node_id)
    redirect_to conversation_path(@conversation)
  end

  def destroy
    @conversation.soft_delete_node!(node_id: @node_id)
    redirect_to conversation_path(@conversation)
  end

  def restore
    @conversation.restore_node!(node_id: @node_id)
    redirect_to conversation_path(@conversation)
  end

  def translate
    target_lang = params.fetch(:target_lang, "").to_s
    @conversation.translate!(node_id: @node_id, target_lang: target_lang)
    redirect_to conversation_path(@conversation)
  end

  private

    def set_conversation
      id = params[:conversation_id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(id)

      @conversation = Current.user.conversations.find_by(id: id)
      raise ActiveRecord::RecordNotFound if @conversation.nil?
    end

    def set_node_id
      @node_id = params[:id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(@node_id)
    end
end
