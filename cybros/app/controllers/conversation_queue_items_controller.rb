class ConversationQueueItemsController < ApplicationController
  before_action :require_authentication
  before_action :set_conversation
  before_action :set_queued_user_node_id

  rescue_from ArgumentError, AgentCore::ValidationError, Cybros::Error do |e|
    render json: { ok: false, error: e.class.name, message: e.message }, status: :unprocessable_entity
  end

  def edit
    @conversation.cancel_queued_turn!(user_node_id: @queued_user_node_id)
    render_update_json
  end

  def steer
    @conversation.steer_queued_turn!(
      user_node_id: @queued_user_node_id,
      model_ref: params.fetch(:model_ref, "").to_s.strip.presence,
      interrupted_output_policy_override: params.fetch(:interrupted_output_policy_override, "").to_s.strip.presence,
    )
    render_update_json
  end

  def destroy
    @conversation.cancel_queued_turn!(user_node_id: @queued_user_node_id)
    render_update_json
  end

  private

    def render_update_json
      page = @conversation.message_page(limit: 30, mode: :full)
      messages = page.fetch("messages")
      composer_state = @conversation.composer_state
      empty_state_id = helpers.dom_id(@conversation, :messages_empty_state)

      streams = [
        view_context.turbo_stream.replace(
          helpers.dom_id(@conversation, :messages_list),
          partial: "conversation_messages/list",
          locals: { conversation: @conversation, messages: messages },
        ),
        view_context.turbo_stream.replace(
          helpers.dom_id(@conversation, :composer_status_rail),
          partial: "conversations/composer_status_rail",
          locals: { conversation: @conversation, composer_state: composer_state },
        ),
      ]

      if messages.any?
        streams << view_context.turbo_stream.remove(empty_state_id)
      end

      render json: { ok: true, turbo_stream: streams.join }
    end

    def set_conversation
      id = params[:conversation_id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(id)

      @conversation = Current.user.conversations.find_by(id: id)
      raise ActiveRecord::RecordNotFound if @conversation.nil?
    end

    def set_queued_user_node_id
      @queued_user_node_id = params[:queued_user_node_id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(@queued_user_node_id)
    end
end
