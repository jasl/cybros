class ConversationMessagesController < ApplicationController
  before_action :require_authentication
  before_action :set_conversation

  def create
    content = params.fetch(:content, "").to_s
    content = content.strip

    if content.blank?
      redirect_to conversation_path(@conversation)
      return
    end

    graph = @conversation.dag_graph
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

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
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
      @conversation = Conversation.find(params[:conversation_id])
    end
end
