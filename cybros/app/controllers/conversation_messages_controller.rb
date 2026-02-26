class ConversationMessagesController < ApplicationController
  include RateLimitable

  before_action :require_authentication
  before_action :set_conversation
  before_action -> { throttle!(key: "messages", limit: 20, period: 60) }, only: :create

  def index
    lane = @conversation.dag_graph.main_lane

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

    page = lane.message_page(limit: 20, before_message_id: before, after_message_id: after, mode: :preview)
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

  def create
    content = params.fetch(:content, "").to_s
    content = content.strip

    if content.blank?
      redirect_to conversation_path(@conversation)
      return
    end

    graph = @conversation.dag_graph
    lane = graph.main_lane
    prev_leaf = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    prev_agent_leaf =
      graph
        .leaf_nodes
        .where(lane_id: lane.id, node_type: Messages::AgentMessage.node_type_key)
        .order(:id)
        .last
    turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: content,
          metadata: {},
        )

      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      if prev_leaf
        m.create_edge(from_node: prev_leaf, to_node: user, edge_type: DAG::Edge::SEQUENCE)
      end
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)

      if prev_agent_leaf && !prev_agent_leaf.terminal?
        m.create_edge(
          from_node: prev_agent_leaf,
          to_node: agent,
          edge_type: DAG::Edge::DEPENDENCY,
          metadata: { "generated_by" => "queue_policy" }
        )
      end
    end

    agent_leaf = graph.leaf_nodes.order(:id).last
    ConversationRun.create!(
      conversation: @conversation,
      dag_node_id: agent_leaf.id,
      state: "queued",
      queued_at: Time.current,
      debug: {},
      error: {},
    )

    graph.kick!

    redirect_to conversation_path(@conversation)
  end

  private

    def set_conversation
      id = params[:conversation_id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(id)

      @conversation = Current.user.conversations.find_by(id: id)
      raise ActiveRecord::RecordNotFound if @conversation.nil?
    end
end
