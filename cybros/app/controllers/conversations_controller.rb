class ConversationsController < AgentController
  include RateLimitable

  before_action :set_conversation, only: %i[show stop retry]
  before_action -> { throttle!(key: "stop_retry", limit: 10, period: 60) }, only: %i[stop retry]

  def index
    before = params[:before].to_s.presence
    after = params[:after].to_s.presence
    if before.present? && after.present?
      render plain: "before and after are mutually exclusive", status: :unprocessable_entity
      return
    end
    if before.present? && !AgentCore::Utils.uuid_like?(before)
      render plain: "before must be a UUID", status: :unprocessable_entity
      return
    end
    if after.present? && !AgentCore::Utils.uuid_like?(after)
      render plain: "after must be a UUID", status: :unprocessable_entity
      return
    end

    page_size = 50
    scope = Current.user.conversations.order(id: :desc)
    scope = scope.where("id < ?", before) if before.present?
    scope = scope.where("id > ?", after) if after.present?

    rows = scope.limit(page_size + 1).to_a
    @has_more = rows.size > page_size
    @conversations = rows.first(page_size)
    @before_cursor = @conversations.last&.id&.to_s
  end

  def create
    title = params.dig(:conversation, :title).to_s.strip
    title = "Conversation" if title.blank?

    conversation =
      Current.user.conversations.create!(
        title: title,
        metadata: { "agent" => { "agent_profile" => "coding" } },
      )

    redirect_to conversation_path(conversation)
  end

  def show
    graph = @conversation.dag_graph
    lane = graph.main_lane

    page = lane.message_page(limit: 30, mode: :preview)
    @messages = page.fetch("messages")
    @before_cursor = page.fetch("before_message_id", nil).to_s.presence

    @has_more =
      if @before_cursor.present?
        lane.message_page(limit: 1, before_message_id: @before_cursor, mode: :preview).fetch("messages").any?
      else
        false
      end
  end

  def stop
    node_id = params[:node_id].to_s
    node = @conversation.dag_graph.nodes.find_by(id: node_id)
    render json: { ok: false, error: "node_not_found" }, status: :not_found and return if node.nil?

    render json: { ok: false, error: "node_not_running" }, status: :unprocessable_entity and return unless node.running?

    node.stop!(reason: "user_cancelled")

    render json: { ok: true }
  end

  def retry
    graph = @conversation.dag_graph

    failed_node_id = params[:node_id].to_s
    failed_node = graph.nodes.find_by(id: failed_node_id)
    render json: { ok: false, error: "node_not_found" }, status: :not_found and return if failed_node.nil?

    unless failed_node.node_type == Messages::AgentMessage.node_type_key
      render json: { ok: false, error: "not_an_agent_node" }, status: :unprocessable_entity and return
    end

    unless failed_node.errored? || failed_node.stopped?
      render json: { ok: false, error: "not_retryable" }, status: :unprocessable_entity and return
    end

    retry_depth = 0
    trace_id = failed_node_id
    while (source_id = graph.nodes.find_by(id: trace_id)&.metadata&.dig("retry_of_node_id"))
      retry_depth += 1
      trace_id = source_id
    end
    if retry_depth >= 5
      render json: { ok: false, error: "retry_limit_reached" }, status: :unprocessable_entity and return
    end

    existing_retry =
      graph.nodes.where(node_type: Messages::AgentMessage.node_type_key, compressed_at: nil).where(
        "metadata ->> 'retry_of_node_id' = ?",
        failed_node_id,
      ).order(:id).last
    if existing_retry && !(existing_retry.finished? || existing_retry.errored? || existing_retry.stopped? || existing_retry.skipped?)
      render json: { ok: false, error: "retry_already_queued" }, status: :conflict and return
    end

    from_node_id =
      graph
        .edges
        .active
        .where(edge_type: DAG::Edge::SEQUENCE, to_node_id: failed_node.id)
        .order(:id)
        .pick(:from_node_id)
    render json: { ok: false, error: "missing_parent" }, status: :unprocessable_entity and return if from_node_id.nil?

    from_node = graph.nodes.find(from_node_id)

    new_agent = nil
    graph.mutate!(turn_id: from_node.turn_id) do |m|
      new_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: { "retry_of_node_id" => failed_node_id },
        )
      m.create_edge(from_node: from_node, to_node: new_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    ConversationRun.create!(
      conversation: @conversation,
      dag_node_id: new_agent.id,
      state: "queued",
      queued_at: Time.current,
      debug: {},
      error: {},
    )

    graph.kick!

    render json: { ok: true, node_id: new_agent.id }
  end

  private

    def set_conversation
      id = params[:id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(id)

      @conversation = Current.user.conversations.find_by(id: id)
      raise ActiveRecord::RecordNotFound if @conversation.nil?
    end
end
