class ConversationsController < AgentController
  include RateLimitable

  rescue_from ArgumentError, Cybros::Error do |e|
    respond_to do |format|
      format.turbo_stream { render plain: e.message, status: :unprocessable_entity }
      format.html { render plain: e.message, status: :unprocessable_entity }
      format.json { render json: { ok: false, error: e.class.name, message: e.message }, status: :unprocessable_entity }
    end
  end

  before_action :set_conversation, only: %i[show stop retry branch regenerate swipe clear_translations]
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

    page_size = 10
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
    page = @conversation.message_page(limit: 30, mode: :full)
    @messages = page.fetch("messages")
    @before_cursor = page.fetch("before_message_id", nil).to_s.presence

    @has_more = @conversation.has_more_messages_before?(before_message_id: @before_cursor)
  end

  def branch
    from_node_id = params.fetch(:from_node_id, "").to_s
    raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(from_node_id)

    title = params.fetch(:title, "").to_s

    child =
      @conversation.create_child!(
        from_node_id: from_node_id,
        kind: "branch",
        title: title.presence || "Branch",
        user_content: params.fetch(:user_content, "").to_s,
      )

    redirect_to conversation_path(child)
  end

  def regenerate
    agent_node_id = params.fetch(:agent_node_id, "").to_s
    raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(agent_node_id)

    result = @conversation.regenerate!(agent_node_id: agent_node_id)
    if result.fetch(:mode) == :branched
      redirect_to conversation_path(result.fetch(:conversation))
    else
      redirect_to conversation_path(@conversation)
    end
  end

  def swipe
    agent_node_id = params.fetch(:agent_node_id, "").to_s
    raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(agent_node_id)

    direction = params.fetch(:direction, "").to_s
    @conversation.select_swipe!(agent_node_id: agent_node_id, direction: direction)
    redirect_to conversation_path(@conversation)
  end

  def clear_translations
    @conversation.clear_translations!
    redirect_to conversation_path(@conversation)
  end

  def stop
    node_id = params[:node_id].to_s
    @conversation.stop_node!(node_id: node_id, reason: "user_cancelled")
    render json: { ok: true }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "node_not_found" }, status: :not_found
  rescue Cybros::Error
    render json: { ok: false, error: "node_not_running" }, status: :unprocessable_entity
  end

  def retry
    failed_node_id = params[:node_id].to_s
    new_id = @conversation.retry_agent_node!(failed_node_id: failed_node_id)
    render json: { ok: true, node_id: new_id }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "node_not_found" }, status: :not_found
  rescue Cybros::Error => e
    code = e.message.to_s
    status = code == "retry_already_queued" ? :conflict : :unprocessable_entity
    render json: { ok: false, error: code }, status: status
  end

  private

    def set_conversation
      id = params[:id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(id)

      @conversation = Current.user.conversations.find_by(id: id)
      raise ActiveRecord::RecordNotFound if @conversation.nil?
    end
end
