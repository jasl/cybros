class ConversationMessagesController < ApplicationController
  include RateLimitable

  before_action :require_authentication
  before_action :set_conversation
  before_action -> { throttle!(key: "messages", limit: 20, period: 60) }, only: :create

  rescue_from ArgumentError, Cybros::Error do |e|
    respond_to do |format|
      format.turbo_stream { render plain: e.message, status: :unprocessable_entity }
      format.html { render plain: e.message, status: :unprocessable_entity }
      format.json { render json: { ok: false, error: e.class.name, message: e.message }, status: :unprocessable_entity }
    end
  end

  def index
    before = params[:before].to_s.presence
    after = params[:after].to_s.presence
    if before.present? && !AgentCore::Utils.uuid_like?(before)
      render plain: "before must be a UUID", status: :unprocessable_entity
      return
    end
    if after.present? && !AgentCore::Utils.uuid_like?(after)
      render plain: "after must be a UUID", status: :unprocessable_entity
      return
    end

    page = @conversation.message_page(limit: 20, before_message_id: before, after_message_id: after, mode: :full)
    @messages = page.fetch("messages")

    before_cursor = page.fetch("before_message_id", nil).to_s.presence
    @has_more = @conversation.has_more_messages_before?(before_message_id: before_cursor)
    @before_cursor = before_cursor

    respond_to do |format|
      format.turbo_stream do
        if @messages.empty?
          load_more_id = helpers.dom_id(@conversation, :messages_load_more)
          render turbo_stream: turbo_stream.replace(
            load_more_id,
            partial: "conversation_messages/load_more",
            locals: { conversation: @conversation, has_more: false, before_cursor: nil }
          )
        else
          action = after.present? ? :append : :prepend
          list_id = helpers.dom_id(@conversation, :messages_list)
          load_more_id = helpers.dom_id(@conversation, :messages_load_more)

          streams = []
          streams << turbo_stream.public_send(
            action,
            list_id,
            partial: "conversation_messages/messages_batch",
            locals: { messages: @messages }
          )
          streams << turbo_stream.replace(
            load_more_id,
            partial: "conversation_messages/load_more",
            locals: { conversation: @conversation, has_more: @has_more, before_cursor: @before_cursor }
          )

          render turbo_stream: streams
        end
      end

      format.html { redirect_to conversation_path(@conversation) }
    end
  end

  def refresh
    node_id = params.fetch(:node_id, "").to_s
    raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(node_id)

    message = @conversation.message_for_node_id(node_id: node_id, mode: :full)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "message_#{node_id}",
          partial: "conversation_messages/message",
          locals: { message: message },
        )
      end

      format.html { redirect_to conversation_path(@conversation) }
    end
  end

  def create
    content = params.fetch(:content, "").to_s
    content = content.strip

    if content.blank?
      respond_to do |format|
        format.turbo_stream { head :no_content }
        format.html { redirect_to conversation_path(@conversation) }
      end
      return
    end

    result = @conversation.append_user_message_and_project!(content: content, mode: :preview)
    created_messages = result.fetch(:messages)

    respond_to do |format|
      format.turbo_stream do
        list_id = helpers.dom_id(@conversation, :messages_list)
        empty_state_id = helpers.dom_id(@conversation, :messages_empty_state)

        render turbo_stream: [
          turbo_stream.append(
            list_id,
            partial: "conversation_messages/messages_batch",
            locals: { messages: created_messages }
          ),
          turbo_stream.remove(empty_state_id),
        ]
      end

      format.html { redirect_to conversation_path(@conversation) }
    end
  end

  private

    def set_conversation
      id = params[:conversation_id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(id)

      @conversation = Current.user.conversations.find_by(id: id)
      raise ActiveRecord::RecordNotFound if @conversation.nil?
    end
end
