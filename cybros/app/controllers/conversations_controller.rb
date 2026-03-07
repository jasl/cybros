class ConversationsController < AgentController
  include RateLimitable

  rescue_from ArgumentError, AgentCore::ValidationError, Cybros::Error do |e|
    respond_to do |format|
      format.turbo_stream { render plain: e.message, status: :unprocessable_entity }
      format.html { render plain: e.message, status: :unprocessable_entity }
      format.json { render json: { ok: false, error: e.class.name, message: e.message }, status: :unprocessable_entity }
    end
  end

  before_action :set_conversation, only: %i[show composer_status start stop retry steer_current_turn branch regenerate swipe clear_translations]
  before_action :throttle_conversation_actions!, only: %i[start stop retry steer_current_turn]

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
    agent_metadata = { "agent_profile" => "coding" }
    default_model_ref = Cybros::AgentRuntimeResolver.default_model_ref_for(agent_metadata: agent_metadata)

    conversation =
      Current.user.conversations.create!(
        title: title,
        metadata: { "agent" => agent_metadata, "llm" => { "model_ref" => default_model_ref } },
      )

    redirect_to conversation_path(conversation)
  rescue AgentCore::ValidationError
    if Current.user&.owner? || Current.user&.admin?
      redirect_to system_settings_llm_providers_path, alert: "No usable default model is configured."
    else
      raise
    end
  end

  def show
    page = @conversation.message_page(limit: 30, mode: :full)
    @messages = page.fetch("messages")
    @before_cursor = page.fetch("before_message_id", nil).to_s.presence

    @has_more = @conversation.has_more_messages_before?(before_message_id: @before_cursor)
    @composer_state = @conversation.composer_state

    begin
      @llm_model_options = Cybros::AgentRuntimeResolver.usable_model_options
      @llm_model_option_groups = build_model_option_groups(@llm_model_options)

      requested_model_ref = @conversation.metadata.dig("llm", "model_ref").to_s.presence
      resolved_default_model_ref = nil
      @model_picker_alert_message = nil
      if requested_model_ref.blank?
        begin
          resolved_default_model_ref =
            Cybros::AgentRuntimeResolver.default_model_ref_for(
              agent_metadata: @conversation.metadata.fetch("agent", {}),
            )
        rescue AgentCore::ValidationError
          resolved_default_model_ref = nil
          @model_picker_alert_message = "Default model is not currently usable. Please reselect a model or fix credentials."
        end
      end
      @stale_model_ref = nil

      if requested_model_ref && @llm_model_options.any? { |o| o.fetch(:model_ref) == requested_model_ref }
        @selected_model_ref = requested_model_ref
      elsif requested_model_ref
        @selected_model_ref = nil
        @stale_model_ref = requested_model_ref
        @model_picker_alert_message = "Selected model is no longer available. Please reselect a model."
      else
        @selected_model_ref =
          if resolved_default_model_ref && @llm_model_options.any? { |o| o.fetch(:model_ref) == resolved_default_model_ref }
            resolved_default_model_ref
          end
      end
    rescue StandardError => e
      Rails.logger.error(
        "Conversation model options failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      )
      @llm_model_options = []
      @llm_model_option_groups = []
      @selected_model_ref = nil
      @stale_model_ref = nil
    end
  end

  def composer_status
    @composer_state = @conversation.composer_state

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          helpers.dom_id(@conversation, :composer_status_rail),
          partial: "conversations/composer_status_rail",
          locals: { conversation: @conversation, composer_state: @composer_state },
        )
      end

      format.html do
        render partial: "conversations/composer_status_rail",
               locals: { conversation: @conversation, composer_state: @composer_state }
      end
    end
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
    respond_to do |format|
      if result.fetch(:mode) == :branched
        destination = conversation_path(result.fetch(:conversation))
        format.turbo_stream { redirect_to destination }
        format.html { redirect_to destination }
      else
        format.turbo_stream { render_conversation_update_streams }
        format.html { redirect_to conversation_path(@conversation) }
      end
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

  def start
    node_id = params[:node_id].to_s
    @conversation.start_pending_agent_node!(node_id: node_id, claimed_by: "manual-start:web:#{Current.user.id}")
    render json: { ok: true }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "node_not_found" }, status: :not_found
  rescue Cybros::Error => e
    status = e.message.to_s == "state_changed" ? :conflict : :unprocessable_entity
    render json: { ok: false, error: e.message.to_s }, status: status
  end

  def retry
    failed_node_id = params[:node_id].to_s
    new_id =
      @conversation.retry_agent_node!(
        failed_node_id: failed_node_id,
        interrupted_output_policy_override: params[:interrupted_output_policy_override],
      )
    render json: { ok: true, node_id: new_id }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "node_not_found" }, status: :not_found
  rescue Cybros::Error => e
    code = e.message.to_s
    status = code == "retry_already_queued" ? :conflict : :unprocessable_entity
    render json: { ok: false, error: code }, status: status
  end

  def steer_current_turn
    content = params.fetch(:content, "").to_s.strip
    model_ref = params.fetch(:model_ref, "").to_s.strip.presence
    input_policy_override = params[:input_policy_override]

    result =
      @conversation.steer_current_turn!(
        content: content,
        model_ref: model_ref,
        input_policy_override: input_policy_override,
        interrupted_output_policy_override: params[:interrupted_output_policy_override],
      )
    raise Cybros::Error, "blank_content" if result.nil?

    respond_to do |format|
      format.json do
        render json: {
          ok: true,
          user_node_id: result[:user_node]&.id,
          node_id: result[:agent_node]&.id,
          product_node_id: result[:product_node]&.id,
        }
      end

      format.turbo_stream { render_conversation_update_streams }
      format.html { redirect_to conversation_path(@conversation) }
    end
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "node_not_found" }, status: :not_found
  rescue Cybros::Error => e
    respond_to do |format|
      format.json { render json: { ok: false, error: e.message.to_s }, status: :unprocessable_entity }
      format.turbo_stream { render plain: e.message, status: :unprocessable_entity }
      format.html { render plain: e.message, status: :unprocessable_entity }
    end
  end

  private

    def throttle_conversation_actions!
      throttle!(key: "start_stop_retry_steer", limit: 10, period: 60)
    end

    def render_conversation_update_streams
      page = @conversation.message_page(limit: 30, mode: :full)
      messages = page.fetch("messages")
      composer_state = @conversation.composer_state

      render turbo_stream: [
        turbo_stream.replace(
          helpers.dom_id(@conversation, :messages_list),
          partial: "conversation_messages/list",
          locals: { conversation: @conversation, messages: messages },
        ),
        turbo_stream.replace(
          helpers.dom_id(@conversation, :composer_status_rail),
          partial: "conversations/composer_status_rail",
          locals: { conversation: @conversation, composer_state: composer_state },
        ),
      ]
    end

    def set_conversation
      id = params[:id].to_s
      raise ActiveRecord::RecordNotFound unless AgentCore::Utils.uuid_like?(id)

      @conversation = Current.user.conversations.find_by(id: id)
      raise ActiveRecord::RecordNotFound if @conversation.nil?
    end

    def build_model_option_groups(options)
      options
        .group_by { |option| [option.fetch(:provider_key), option.fetch(:provider_display_name)] }
        .map do |(provider_key, provider_display_name), grouped_options|
          {
            provider_key: provider_key,
            provider_display_name: provider_display_name,
            options: grouped_options,
          }
        end
    end
end
