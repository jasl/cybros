class ConversationMessagesController < ApplicationController
  include RateLimitable

  before_action :require_authentication
  before_action :set_conversation
  before_action -> { throttle!(key: "messages", limit: 20, period: 60) }, only: :create

  def index
    lane = @conversation.chat_lane

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

    page = lane.message_page(limit: 20, before_message_id: before, after_message_id: after, mode: :full)
    @messages = page.fetch("messages")

    before_cursor = page.fetch("before_message_id", nil).to_s.presence
    @has_more =
      if before_cursor.present?
        lane.message_page(limit: 1, before_message_id: before_cursor, mode: :preview).fetch("messages").any?
      else
        false
      end
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
  rescue DAG::PaginationError => e
    respond_to do |format|
      format.turbo_stream { render plain: e.message, status: :unprocessable_entity }
      format.html { render plain: e.message, status: :unprocessable_entity }
    end
  end

  def refresh
    node_id = params.fetch(:node_id, "").to_s
    raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(node_id)

    graph = @conversation.root_graph
    node = graph.nodes.find_by(id: node_id)
    raise ActiveRecord::RecordNotFound if node.nil?

    projection = DAG::TranscriptProjection.new(graph: graph)
    message = projection.project(node_records: [node], mode: :full).first
    raise ActiveRecord::RecordNotFound unless message.is_a?(Hash)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "message_#{node.id}",
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

    graph = @conversation.root_graph
    result = @conversation.append_user_message!(content: content)
    user_node = result&.fetch(:user_node, nil)
    agent_node = result&.fetch(:agent_node, nil)

    respond_to do |format|
      format.turbo_stream do
        projection = DAG::TranscriptProjection.new(graph: graph)
        created_messages = projection.project(node_records: [user_node, agent_node].compact, mode: :preview)

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
