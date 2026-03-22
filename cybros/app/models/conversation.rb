require "digest"

class Conversation < ApplicationRecord
  KINDS = %w[root branch thread checkpoint].freeze
  TERMINAL_NODE_STATES = %w[finished errored stopped rejected skipped].freeze
  IN_FLIGHT_NODE_STATES = %w[pending awaiting_approval running].freeze
  STATISTICS_SAMPLE_ORIGINS = %w[runtime eval debug replay].freeze
  DEFAULT_STATISTICS_SAMPLE_ORIGIN = "runtime"
  MAX_ATTACHMENTS_PER_MESSAGE = 10
  MAX_ATTACHMENT_BYTES = 25.megabytes
  COMPOSER_DRAFT_KEYS = %w[content model_ref permission_mode updated_at].freeze
  COMPOSER_DRAFT_KEEP = Object.new
  PERMISSION_MODES = Cybros::Permissions::MODES
  PERMISSION_MODE_LABELS = Cybros::Permissions::LABELS.freeze

  belongs_to :user
  belongs_to :automation, optional: true
  belongs_to :agent, optional: true

  has_one :dag_graph,
          class_name: "DAG::Graph",
          as: :attachable,
          dependent: :destroy,
          autosave: true

  delegate :mutate!, :compress!, :kick!, to: :root_graph, allow_nil: false

  has_one :dag_lane, as: :attachable, class_name: "DAG::Lane", dependent: :nullify

  belongs_to :parent_conversation, class_name: "Conversation", optional: true
  belongs_to :root_conversation, class_name: "Conversation", optional: true
  has_many :branch_conversations,
           class_name: "Conversation",
           foreign_key: :parent_conversation_id,
           dependent: :destroy,
           inverse_of: :parent_conversation

  has_many :events, dependent: :destroy
  has_many :conversation_attachments, dependent: :destroy
  has_many :conversation_runs, dependent: :destroy
  has_many :lane_processes, dependent: :destroy
  has_many :run_drafts, dependent: :destroy
  has_many :turn_internal_tasks, dependent: :destroy
  has_many :owned_subagent_threads,
           class_name: "SubagentThread",
           foreign_key: :owner_conversation_id,
           dependent: :restrict_with_exception,
           inverse_of: :owner_conversation
  has_one :subagent_thread,
          class_name: "SubagentThread",
          foreign_key: :child_conversation_id,
          dependent: :restrict_with_exception,
          inverse_of: :child_conversation

  after_initialize do
    build_dag_graph if new_record? && dag_graph.nil? && root?
  end

  enum :kind, KINDS.index_by(&:itself), default: "root"

  before_validation :assign_root_conversation, on: :create
  before_validation :ensure_statistics_sample_origin, on: :create
  before_validation :assign_default_agent, on: :create
  before_validation :normalize_runtime_settings
  after_create :set_root_conversation_to_self, if: :root?

  validates :permission_mode, presence: true, inclusion: { in: PERMISSION_MODES }
  validates :agent, presence: true
  attr_accessor :bootstrap_lane_first_user_message_node_id

  after_create_commit :dispatch_bootstrap_hooks_after_commit

  def dag_node_body_namespace
    Messages
  end

  def dag_graph_hooks
    @dag_graph_hooks ||= Messages::GraphHooks.new(conversation: root_conversation || self)
  end

  def dag_graph_policy
    if Rails.env.test?
      key = metadata.is_a?(Hash) ? metadata["dag_graph_policy"].to_s : ""
      return DAG::GraphPolicy::ALLOW_ALL unless key == "product"
    end

    @dag_graph_policy ||= Messages::GraphPolicy.new(conversation: root_conversation || self)
  end

  def root_graph
    root? ? dag_graph : root_conversation!.dag_graph
  end

  def message_page(limit:, before_message_id: nil, after_message_id: nil, mode: :full)
    raw = Integer(limit.to_s, exception: false)
    raise ArgumentError, "limit must be an integer" if raw.nil?
    raise ArgumentError, "limit must be >= 1" if raw < 1

    page =
      chat_lane.message_page(
        limit: raw,
        before_message_id: before_message_id.to_s.presence,
        after_message_id: after_message_id.to_s.presence,
        mode: mode,
      )

    decorate_message_page(page)
  rescue DAG::PaginationError => e
    raise Cybros::Error, e.message
  end

  def transcript_page(limit_turns:, before_turn_id: nil, after_turn_id: nil, mode: :preview, include_deleted: false)
    page =
      chat_lane.transcript_page(
        limit_turns: limit_turns,
        before_turn_id: before_turn_id,
        after_turn_id: after_turn_id,
        mode: mode,
        include_deleted: include_deleted,
      )

    decorate_transcript_page(page)
  rescue DAG::PaginationError => e
    raise Cybros::Error, e.message
  end

  def transcript_recent_turns(limit_turns:, mode: :preview, include_deleted: false)
    decorate_messages(
      chat_lane.transcript_recent_turns(
        limit_turns: limit_turns,
        mode: mode,
        include_deleted: include_deleted,
      )
    )
  rescue DAG::PaginationError => e
    raise Cybros::Error, e.message
  end

  def transcript_for(target_node_id, limit_turns: nil, limit: nil, mode: :preview, include_deleted: false)
    decorate_messages(
      root_graph.transcript_for(
        target_node_id,
        limit_turns: limit_turns || DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS,
        limit: limit,
        mode: mode,
        include_deleted: include_deleted,
      )
    )
  rescue DAG::ValidationError, DAG::OperationNotAllowedError, DAG::PaginationError, DAG::SafetyLimits::Exceeded => e
    raise Cybros::Error, e.message
  end

  def context_for(target_node_id, limit_turns: nil, mode: :preview, include_excluded: false, include_deleted: false)
    chat_lane.context_for(
      target_node_id,
      limit_turns: limit_turns || DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS,
      mode: mode,
      include_excluded: include_excluded,
      include_deleted: include_deleted,
    )
  rescue DAG::ValidationError, DAG::OperationNotAllowedError, DAG::PaginationError, DAG::SafetyLimits::Exceeded => e
    raise Cybros::Error, e.message
  end

  def has_more_messages_before?(before_message_id:)
    before = before_message_id.to_s.presence
    return false if before.blank?

    message_page(limit: 1, before_message_id: before, mode: :preview).fetch("messages").any?
  end

  def messages_for_node_ids(node_ids:, mode: :full)
    ids = Array(node_ids).compact.map(&:to_s).select(&:present?)
    return [] if ids.empty?

    nodes_by_id = root_graph.nodes.where(id: ids).to_a.index_by { |n| n.id.to_s }
    nodes = ids.filter_map { |id| nodes_by_id[id] }

    projection = transcript_projection
    projection.project(node_records: nodes, mode: mode)
  end

  def message_for_node_id(node_id:, mode: :full)
    node = find_chat_lane_node!(node_id)

    projection = transcript_projection
    message = projection.project(node_records: [node], mode: mode).first
    raise ActiveRecord::RecordNotFound unless message.is_a?(Hash)

    message
  end

  def action_policy_for(node)
    Conversation::NodeActionPolicy.new(conversation: self, node: node).to_h
  end

  def resolved_input_policy(app_override: nil, action: nil, interrupted_output_policy_override: nil)
    Conversation::InputPolicyResolver.resolve(
      conversation: self,
      app_override: app_override,
      action: action,
      interrupted_output_policy_override: interrupted_output_policy_override,
    )
  end

  def action_policy_for_node_id(node_id)
    action_policy_for(find_chat_lane_node!(node_id))
  end

  def composer_state(now: Time.current)
    Conversation::ComposerState.build(conversation: self, now: now)
  end

  def active_lane_processes
    LaneProcesses::Reconciler.call!(conversation: self)
    lane_processes.active.recent_first
  end

  def managed_subagent_thread
    subagent_thread
  rescue StandardError
    nil
  end

  def managed_subagent_child?
    managed_subagent_thread.present?
  end

  def managed_subagent_read_only?
    thread = managed_subagent_thread
    return false if thread.nil?

    Current.subagent_owner_proxy_thread_id.to_s != thread.id.to_s
  end

  def managed_subagent_read_only_reason
    managed_subagent_read_only? ? "managed_subagent_read_only" : nil
  end

  def selected_agent_config
    selected_agent_config_for(agent)
  end

  def selected_agent_config_for(agent_like)
    namespace = agent_like&.config_namespace.to_s.strip
    return {} if namespace.empty?

    config = self[:agent_config]
    return {} unless config.is_a?(Hash)

    value = config.deep_stringify_keys.fetch(namespace, nil)
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end

  def resolved_composer_draft
    draft = normalized_composer_draft_payload(self[:composer_draft])

    {
      "content" => draft.fetch("content", ""),
      "model_ref" => draft["model_ref"].presence || metadata_model_ref,
      "permission_mode" => draft["permission_mode"].presence || permission_mode,
    }.compact
  end

  def composer_draft_updated_at
    normalized_composer_draft_payload(self[:composer_draft])["updated_at"].to_s.presence
  end

  def update_composer_draft!(
    content: COMPOSER_DRAFT_KEEP,
    model_ref: COMPOSER_DRAFT_KEEP,
    permission_mode: COMPOSER_DRAFT_KEEP,
    updated_at: COMPOSER_DRAFT_KEEP
  )
    assert_mutation_allowed_for_managed_subagent!

    draft = normalized_composer_draft_payload(self[:composer_draft])
    current_updated_at = parse_composer_draft_timestamp(draft["updated_at"])
    requested_updated_at = updated_at == COMPOSER_DRAFT_KEEP ? nil : parse_composer_draft_timestamp(updated_at)

    if requested_updated_at.present? && current_updated_at.present? && requested_updated_at <= current_updated_at
      return self
    end

    if content != COMPOSER_DRAFT_KEEP
      next_content = content.to_s
      next_content.present? ? draft["content"] = next_content : draft.delete("content")
    end

    if model_ref != COMPOSER_DRAFT_KEEP
      next_model_ref = model_ref.to_s.strip
      if next_model_ref.present?
        Cybros::AgentRuntimeResolver.validate_model_ref!(model_ref: next_model_ref)
        draft["model_ref"] = next_model_ref
      else
        draft.delete("model_ref")
      end
    end

    if permission_mode != COMPOSER_DRAFT_KEEP
      next_permission_mode = permission_mode.to_s.strip
      if next_permission_mode.present?
        unless PERMISSION_MODES.include?(next_permission_mode)
          AgentCore::ValidationError.raise!(
            "Permission mode is invalid.",
            code: "cybros.conversations.invalid_permission_mode",
            details: { permission_mode: next_permission_mode },
          )
        end

        draft["permission_mode"] = next_permission_mode
      else
        draft.delete("permission_mode")
      end
    end

    normalized_updated_at = requested_updated_at&.utc&.iso8601(6)
    if draft.except("updated_at").any?
      draft["updated_at"] = normalized_updated_at || Time.current.utc.iso8601(6)
    elsif updated_at != COMPOSER_DRAFT_KEEP
      draft = { "updated_at" => normalized_updated_at || Time.current.utc.iso8601(6) }
    else
      draft = {}
    end

    update!(composer_draft: draft)
  end

  def workspace_root_path
    agent.workspace_root_path.join("conversations", id.to_s).cleanpath
  end

  def lane_workspace_root_path(lane_id:)
    workspace_root_path.join(".lanes", lane_id.to_s).cleanpath
  end

  def workspace_payload(lane_id: nil)
    lane_id = lane_id.presence || chat_lane&.id
    initialized = Conversations::WorkspaceInitializer.initialize!(conversation: self)
    lane_path =
      if lane_id.present?
        Conversations::WorkspaceInitializer.materialize_lane_directory!(conversation: self, lane_id: lane_id).to_s
      end

    {
      "conversation_id" => id,
      "root_path" => initialized.fetch(:agent_root_path).to_s,
      "conversation_path" => initialized.fetch(:conversation_path).to_s,
      "lane_path" => lane_path,
      "cwd" => initialized.fetch(:cwd).to_s,
    }.compact
  end

  def statistics_sample_origin
    self.class.normalize_statistics_sample_origin(metadata.is_a?(Hash) ? metadata.dig("statistics", "sample_origin") : nil)
  end

  def self.normalize_statistics_sample_origin(value)
    normalized = value.to_s.strip
    return DEFAULT_STATISTICS_SAMPLE_ORIGIN if normalized.blank?
    return normalized if STATISTICS_SAMPLE_ORIGINS.include?(normalized)

    DEFAULT_STATISTICS_SAMPLE_ORIGIN
  end

  def append_user_message_and_project!(content:, attachments: nil, mode: :preview, model_ref: nil, permission_mode: nil, input_policy_override: nil, diagnostic_level: nil)
    result =
      append_user_message!(
        content: content,
        attachments: attachments,
        model_ref: model_ref,
        permission_mode: permission_mode,
        input_policy_override: input_policy_override,
        diagnostic_level: diagnostic_level,
      )
    raise Cybros::Error, "failed to append message" if result.nil?

    node_ids =
      [
        result[:user_node]&.id,
        result[:guard_node]&.id,
        result[:compact_task]&.id,
        result[:product_node]&.id,
        result[:agent_node]&.id,
      ].compact
    {
      messages: messages_for_node_ids(node_ids: node_ids, mode: mode),
      node_ids: node_ids,
      composer_state: composer_state,
    }
  end

  def edit_user_message!(node_id:, content:, model_ref: nil, permission_mode: nil, input_policy_override: nil)
    content = content.to_s.strip
    return nil if content.blank?
    assert_mutation_allowed_for_managed_subagent!

    with_dag_errors_wrapped do
      graph = root_graph
      lane = chat_lane
      model_ref = resolve_model_ref!(requested_model_ref: model_ref)
      policy = resolved_input_policy(app_override: input_policy_override)

      user_node = nil
      guard_node = nil
      compact_task = nil
      agent_node = nil
      product_node = nil
      created_new_run = false

      graph.with_graph_lock! do
        target = graph.nodes.active.find(node_id)
        raise ArgumentError, "not a user node" unless target.node_type == Messages::UserMessage.node_type_key
        raise ArgumentError, "wrong lane" unless target.lane_id.to_s == lane.id.to_s

        edit_action = action_entry_for(target, "edit")
        if !edit_action.fetch("available", false)
          reason = edit_action.fetch("reason", "not_editable_now")
          raise Cybros::Error, "Editing attachments is not supported yet." if reason == "attachments_not_editable"
          raise Cybros::Error, reason
        end
        raise Cybros::Error, "Editing attachments is not supported yet." if Array(target.body_input["attachments"]).any?

        mutations = DAG::Mutations.new(graph: graph)
        user_node = mutations.edit_replace!(node: target, new_input: { "content" => content })

        created =
          create_guarded_continuation_for_existing_turn!(
            graph: graph,
            lane: lane,
            base_node: user_node,
            user_node: user_node,
            content: content,
            model_ref: model_ref,
            input_policy: policy,
          )

        guard_node = created[:guard_node]
        compact_task = created[:compact_task]
        agent_node = created[:agent_node]
        product_node = created[:product_node]
        created_new_run = agent_node.present?
      end

      reset_turn_internal_execution!(
        graph: graph,
        turn_id: user_node.turn_id,
        preserve_node_ids: [user_node&.id, guard_node&.id, compact_task&.id, agent_node&.id, product_node&.id].compact,
        compressed_by_id: agent_node&.id || product_node&.id || user_node.id,
        reason: "turn_reset",
      )

      if created_new_run
        if enqueue_conversation_run!(
             agent_node: agent_node,
             selected_model_ref: model_ref,
             permission_mode: permission_mode,
             user_input: content,
             debug: {},
             error: {},
           )
          graph.kick!
        end
      end

      {
        user_node: user_node,
        guard_node: guard_node,
        compact_task: compact_task,
        agent_node: agent_node,
        product_node: product_node,
      }
    end
  end

  def stop_node!(node_id:, reason: "user_cancelled")
    assert_mutation_allowed_for_managed_subagent!

    with_dag_errors_wrapped do
      node = find_chat_lane_node!(node_id)
      raise Cybros::Error, "node_not_running" unless node_stoppable?(node)
      parked_draft = parked_run_draft_for_node!(node.id) if node.state == DAG::Node::AWAITING_APPROVAL

      stopped = node.stop!(reason: reason.to_s)
      raise Cybros::Error, "node_not_running" unless stopped

      cancel_runs_for_node!(node)
      cancel_parked_approval!(draft: parked_draft, reason: reason.to_s) if parked_draft.present?
      node
    end
  end

  def start_pending_agent_node!(node_id:, claimed_by:)
    assert_mutation_allowed_for_managed_subagent!

    with_dag_errors_wrapped do
      graph = root_graph
      lane = chat_lane
      claimed_by = claimed_by.to_s.presence || "manual-start:conversation:#{id}"
      started_node = nil
      enqueue_execution = false

      graph.with_graph_lock! do
        now = Time.current
        repair_stale_pending_middle_agents!(graph: graph, lane: lane, now: now)

        started_node = graph.nodes.find_by(id: node_id.to_s)
        raise ActiveRecord::RecordNotFound if started_node.nil?
        raise ActiveRecord::RecordNotFound unless started_node.lane_id.to_s == lane.id.to_s
        raise Cybros::Error, "state_changed" unless startable_pending_agent?(node: started_node)
        raise Cybros::Error, "state_changed" unless pending_agent_dependencies_satisfied?(graph: graph, agent_node: started_node)

        claimed_node = claim_pending_agent_for_manual_start!(graph: graph, agent_node: started_node, claimed_by: claimed_by, now: now)
        started_node = claimed_node || started_node.reload
        enqueue_execution = started_node.running?
      end

      DAG::ExecuteNodeJob.perform_later(started_node.id) if enqueue_execution
      started_node
    end
  end

  def approve_parked_agent_node!(node_id:, approved_by:)
    assert_mutation_allowed_for_managed_subagent!

    with_dag_errors_wrapped do
      node = find_chat_lane_node!(node_id)
      raise Cybros::Error, "state_changed" unless node.state == DAG::Node::AWAITING_APPROVAL

      draft = parked_run_draft_for_node!(node.id)
      approved_at = Time.current
      draft.update!(
        approval_state:
          draft.approval_state.merge(
            "status" => "approved",
            "approved_at" => approved_at.iso8601,
            "approved_by" => approved_by.to_s,
          ),
      )

      RunDrafts::ApprovalResumeService.resume!(draft: draft)
      start_pending_agent_node!(node_id: node.id, claimed_by: approved_by.to_s)
    end
  end

  def deny_parked_agent_node!(node_id:, denied_by:, reason: "approval_denied")
    assert_mutation_allowed_for_managed_subagent!

    with_dag_errors_wrapped do
      node = find_chat_lane_node!(node_id)
      raise Cybros::Error, "state_changed" unless node.state == DAG::Node::AWAITING_APPROVAL

      draft = parked_run_draft_for_node!(node.id)
      denied_at = Time.current
      approval_state =
        draft.approval_state.merge(
          "status" => "rejected",
          "reason" => reason.to_s,
          "denied_at" => denied_at.iso8601,
          "denied_by" => denied_by.to_s,
        )

      RunDrafts::DiscardService.discard!(draft: draft, status: "discarded", approval_state: approval_state)
      node.deny_approval!(reason: reason.to_s)
      node
    end
  end

  def retry_agent_node!(failed_node_id:, interrupted_output_policy_override: nil, diagnostic_level: nil)
    assert_mutation_allowed_for_managed_subagent!

    with_dag_errors_wrapped do
      graph = root_graph
      diagnostic_level = normalize_turn_execution_diagnostic_level(diagnostic_level)

      failed_node = graph.nodes.find_by(id: failed_node_id.to_s)
      raise ActiveRecord::RecordNotFound if failed_node.nil?
      raise ActiveRecord::RecordNotFound unless failed_node.lane_id.to_s == chat_lane.id.to_s

      raise Cybros::Error, "not_an_agent_node" unless failed_node.node_type == Messages::AgentMessage.node_type_key
      retry_action = action_entry_for(failed_node, "retry")
      unless retry_action.fetch("available", false)
        code =
          case retry_action["reason"].to_s
          when "retry_already_queued"
            "retry_already_queued"
          when "missing_parent"
            "missing_parent"
          else
            "not_retryable"
          end
        raise Cybros::Error, code
      end

      retry_policy =
        resolved_input_policy(
          action: "retry",
          interrupted_output_policy_override: interrupted_output_policy_override,
        )
      apply_interrupted_output_policy!(
        node: failed_node,
        interrupted_output_policy: retry_policy.fetch("interrupted_output_policy"),
      )

      new_agent = failed_node.retry!
      reanchor_turn_internal_tasks_for_retry!(
        turn_id: failed_node.turn_id,
        from_node_id: failed_node.id,
        to_node_id: new_agent.id,
      )
      apply_turn_execution_diagnostic_level!(new_agent, diagnostic_level: diagnostic_level)

      if enqueue_conversation_run!(
           agent_node: new_agent,
           selected_model_ref: new_agent.metadata.dig("llm", "model_ref"),
           user_input: "",
           debug: turn_execution_debug_payload(diagnostic_level),
           error: {},
         )
        graph.kick!
      end

      new_agent.id
    end
  end

  def steer_current_turn!(content:, model_ref: nil, input_policy_override: nil, interrupted_output_policy_override: nil)
    content = content.to_s.strip
    return nil if content.blank?
    assert_mutation_allowed_for_managed_subagent!

    with_dag_errors_wrapped do
      graph = root_graph
      lane = chat_lane
      raise Cybros::Error, "no_running_turn" if latest_executing_agent_for_lane(graph: graph, lane: lane).nil?

      steer_policy =
        resolved_input_policy(
          app_override: input_policy_override,
          action: "steer_current_turn",
          interrupted_output_policy_override: interrupted_output_policy_override,
        )

      unless steer_policy.fetch("steer_capability")
        return append_user_message!(
          content: content,
          model_ref: model_ref,
          input_policy_override: steer_fallback_input_policy_override(
            input_policy_override: input_policy_override,
            steer_policy: steer_policy,
          ),
        )
      end

      model_ref = resolve_model_ref!(requested_model_ref: model_ref)

      user_node = nil
      guard_node = nil
      compact_task = nil
      agent_node = nil
      product_node = nil
      created_new_run = false
      fallback_required = false

      graph.with_graph_lock! do
        running_agent = latest_executing_agent_for_lane(graph: graph, lane: lane)
        raise Cybros::Error, "no_running_turn" if running_agent.nil?

        current_user = stable_sequence_parent_for(node: running_agent)
        if current_user.nil? || current_user.node_type != Messages::UserMessage.node_type_key
          fallback_required = true
          next
        end

        if steer_blocked_by_side_effects?(user_node: current_user, steer_policy: steer_policy)
          fallback_required = true
          next
        end

        stop_causal_closure!(root_node: running_agent, reason: "steer_current_turn")

        preserved_text =
          if steer_policy.fetch("interrupted_output_policy") == "keep_context"
            superseded_block_context_for(user_node: current_user, agent_node: running_agent)
          end

        mutations = DAG::Mutations.new(graph: graph)
        user_node = mutations.edit_replace!(node: current_user, new_input: { "content" => content })
        annotate_steered_user_node!(
          user_node: user_node,
          content: content,
          steer_policy: steer_policy,
        )

        base_node =
          maybe_create_steer_context_node!(
            lane: lane,
            mutations: mutations,
            user_node: user_node,
            preserved_text: preserved_text,
            steer_policy: steer_policy,
          ) || user_node

        created =
          create_guarded_continuation_for_existing_turn!(
            graph: graph,
            lane: lane,
            base_node: base_node,
            user_node: user_node,
            content: content,
            model_ref: model_ref,
            input_policy: steer_policy,
            additional_context_text: preserved_text,
          )

        guard_node = created[:guard_node]
        compact_task = created[:compact_task]
        agent_node = created[:agent_node]
        product_node = created[:product_node]
        created_new_run = agent_node.present?
      end

      if fallback_required
        return append_user_message!(
          content: content,
          model_ref: model_ref,
          input_policy_override:
            steer_fallback_input_policy_override(
              input_policy_override: input_policy_override,
              steer_policy: steer_policy,
            ),
        )
      end

      if created_new_run
        if enqueue_conversation_run!(
             agent_node: agent_node,
             selected_model_ref: model_ref,
             user_input: content,
             debug: {},
             error: {},
           )
          graph.kick!
        end
      end

      {
        user_node: user_node,
        guard_node: guard_node,
        compact_task: compact_task,
        agent_node: agent_node,
        product_node: product_node,
      }
    end
  end

  def queued_turn_items(now: Time.current)
    graph = root_graph
    lane = chat_lane
    queue_anchor_agent = queue_anchor_agent_for_lane(graph: graph, lane: lane)
    return [] if queue_anchor_agent.nil?

    graph.nodes.active
      .where(
        lane_id: lane.id,
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::PENDING,
      )
      .where.not(turn_id: queue_anchor_agent.turn_id)
      .order(:id)
      .filter_map do |agent_node|
        user_node =
          graph.nodes.active
            .where(
              lane_id: lane.id,
              turn_id: agent_node.turn_id,
              node_type: Messages::UserMessage.node_type_key,
            )
            .order(:id)
            .last

        next if user_node.nil?

        {
          "turn_id" => agent_node.turn_id.to_s,
          "user_node_id" => user_node.id.to_s,
          "agent_node_id" => agent_node.id.to_s,
          "content" => user_node.body_input["content"].to_s.strip,
          "model_ref" => agent_node.metadata.dig("llm", "model_ref").to_s.presence,
        }
      end
  end

  def cancel_queued_turn!(user_node_id:)
    rewrite_queued_turns!(selected_user_node_id: user_node_id, mode: :cancel)
  end

  def steer_queued_turn!(user_node_id:, model_ref: nil, interrupted_output_policy_override: nil)
    rewrite_queued_turns!(
      selected_user_node_id: user_node_id,
      mode: :steer,
      model_ref: model_ref,
      interrupted_output_policy_override: interrupted_output_policy_override,
    )
  end

  def output_preview_for_node_id(node_id)
    id = node_id.to_s
    return {} if id.blank?

    body_id = root_graph.nodes.where(id: id).pick(:body_id)
    preview = body_id.present? ? DAG::NodeBody.where(id: body_id).pick(:output_preview) : {}
    preview.is_a?(Hash) ? preview : {}
  end

  def turn_id_for_node_id(node_id)
    root_graph.nodes.where(id: node_id.to_s).pick(:turn_id)&.to_s
  end

  def latest_node_event_id_for(node_id)
    chat_lane.node_event_scope_for(node_id.to_s).order(id: :desc).limit(1).pick(:id)&.to_s
  end

  def cursor_for_existing_output(node_id)
    message = message_for_node_id(node_id: node_id, mode: :preview)
    run_state_cursor = message.dig("run_state", "event_cursor").to_s.presence
    return run_state_cursor if run_state_cursor.present?

    preview = output_preview_for_node_id(node_id)
    return nil if preview.fetch("content", "").to_s.blank?

    latest_node_event_id_for(node_id)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def node_event_page_for(node_id, after_event_id:, limit:, kinds:)
    chat_lane.node_event_page_for(
      node_id.to_s,
      after_event_id: after_event_id.to_s.presence,
      limit: limit,
      kinds: Array(kinds).map(&:to_s),
    )
  end

  def execution_event_page_for_node_id(node_id, after_event_id:, limit:)
    node = find_chat_lane_node!(node_id)

    raw_limit = Integer(limit.to_s, exception: false)
    raise ArgumentError, "limit must be an integer" if raw_limit.nil?
    raise ArgumentError, "limit must be >= 1" if raw_limit < 1

    scope = execution_event_scope_for_node(node).order(:id)
    scope = scope.where("id > ?", after_event_id.to_s) if after_event_id.to_s.present?

    scope
      .limit([raw_limit, 200].min)
      .select(:id, :node_id, :turn_id, :kind, :text, :payload, :created_at)
      .map do |event|
        {
          "event_id" => event.id,
          "node_id" => event.node_id,
          "turn_id" => event.turn_id,
          "kind" => event.kind,
          "text" => event.text,
          "payload" => event.payload,
          "created_at" => event.created_at&.iso8601,
        }
      end
  end

  def append_user_message!(content:, attachments: nil, model_ref: nil, permission_mode: nil, input_policy_override: nil, repair_pending_tail: true, diagnostic_level: nil)
    uploaded_attachments = normalize_uploaded_attachments(attachments)
    content = content.to_s.strip
    return nil if content.blank? && uploaded_attachments.empty?
    validate_attachment_constraints!(uploaded_attachments) if uploaded_attachments.any?
    validate_attachment_support!(uploaded_attachments) if uploaded_attachments.any?
    assert_mutation_allowed_for_managed_subagent!

    with_dag_errors_wrapped do
      graph = root_graph
      lane = chat_lane
      diagnostic_level = normalize_turn_execution_diagnostic_level(diagnostic_level)
      model_ref = resolve_model_ref!(requested_model_ref: model_ref)
      policy = resolved_input_policy(app_override: input_policy_override)
      now = Time.current
      claim_after_at = uploaded_attachments.any? ? nil : coalescing_claim_after_at(policy: policy, now: now)
      running_input_policy = policy["running_input_policy"].to_s.presence || "queue"

      user_node = nil
      guard_node = nil
      compact_task = nil
      agent_node = nil
      product_node = nil
      created_new_turn = false
      lane_first_user_message_node = nil

      graph.with_graph_lock! do
        running_agent = latest_executing_agent_for_lane(graph: graph, lane: lane)
        sequence_parent = nil
        dependency_parent = nil
        had_prior_lane_user_messages =
          graph.nodes.active.where(lane_id: lane.id, node_type: Messages::UserMessage.node_type_key).exists?

        if running_agent.present? && running_input_policy == "interrupt_new_turn"
          interrupted =
            interrupt_new_turn!(
              running_agent: running_agent,
              interrupted_output_policy: policy.fetch("interrupted_output_policy"),
            )
          sequence_parent = interrupted.fetch(:stable_parent)
        else
          coalesced_turn =
            coalescible_turn_for_lane(
              graph: graph,
              lane: lane,
              now: now,
            )

          if claim_after_at.present? && coalesced_turn.present?
            user_node = coalesced_turn.fetch(:user_node)
            agent_node = coalesced_turn.fetch(:agent_node)
            merge_user_message_fragment!(user_node: user_node, content: content)
            refresh_pending_agent_for_fragment!(agent_node: agent_node, model_ref: model_ref, claim_after_at: claim_after_at)
          else
            if running_agent.blank? && repair_pending_tail
              repair_stale_pending_middle_agents!(graph: graph, lane: lane, now: now)
              repair_stale_tail_pending_agent!(graph: graph, lane: lane, now: now)
            end
            sequence_parent = head_leaf_for_lane(graph: graph, lane: lane)
            dependency_parent = head_leaf_for_lane(graph: graph, lane: lane, node_type: Messages::AgentMessage.node_type_key)
          end
        end

        if user_node.nil? && agent_node.nil? && product_node.nil?
          created =
            create_guarded_user_turn!(
              graph: graph,
              lane: lane,
              content: content,
              model_ref: model_ref,
              claim_after_at: claim_after_at,
              sequence_parent: sequence_parent,
              dependency_parent: dependency_parent,
              input_policy: policy,
            )
          user_node = created.fetch(:user_node)
          guard_node = created[:guard_node]
          compact_task = created[:compact_task]
          agent_node = created[:agent_node]
          product_node = created[:product_node]
          if user_node.present? && uploaded_attachments.any?
            manifest = persist_message_attachments!(user_node: user_node, uploaded_attachments: uploaded_attachments)
            annotate_user_message_attachments!(user_node: user_node, attachments_manifest: manifest)
          end
          created_new_turn = agent_node.present?
          lane_first_user_message_node = user_node if user_node.present? && !had_prior_lane_user_messages
        end
      end

      if created_new_turn
        apply_turn_execution_diagnostic_level!(agent_node, diagnostic_level: diagnostic_level)

        if enqueue_conversation_run!(
             agent_node: agent_node,
             selected_model_ref: model_ref,
             permission_mode: permission_mode,
             user_input: content,
             debug: turn_execution_debug_payload(diagnostic_level),
             error: {},
           )
         graph.kick!
        end
      end

      if lane_first_user_message_node.present?
        Conversations::BootstrapHookDispatcher.dispatch_lane_first_user_message!(
          conversation: self,
          user_node: lane_first_user_message_node,
          anchor_node: agent_node || product_node || chat_head_leaf,
        )
      end

      {
        user_node: user_node,
        guard_node: guard_node,
        compact_task: compact_task,
        agent_node: agent_node,
        product_node: product_node,
      }
    end
  end

  def create_child!(from_node_id:, kind:, title:, user_content:)
    with_dag_errors_wrapped do
      kind = kind.to_s
      raise ArgumentError, "invalid kind" unless KINDS.include?(kind)
      raise ArgumentError, "kind must not be root" if kind == "root"

      title = title.to_s.strip
      title = "Conversation" if title.blank?

      graph = root_graph
      source_lane = chat_lane
      from_node = graph.nodes.active.find(from_node_id)
      raise ArgumentError, "wrong lane" unless from_node.lane_id.to_s == source_lane.id.to_s
      raise ArgumentError, "from_node must be terminal" unless from_node.terminal?
      raise Cybros::Error, "cannot fork from deleted node" if from_node.deleted?
      raise Cybros::Error, "node type is not forkable: #{from_node.node_type}" unless from_node.body&.forkable?

      child = nil
      root_node = nil

      Conversation.transaction do
        child =
          Conversation.create!(
            user: user,
            title: title,
            metadata: metadata,
            agent: agent,
            permission_mode: permission_mode,
            agent_config: agent_config,
            agent_config_schema_fingerprint: agent_config_schema_fingerprint,
            kind: kind,
            parent_conversation: self,
            forked_from_node_id: from_node.id,
          )

        graph.mutate! do |m|
          root_node = fork_child_root_node!(mutations: m, from_node: from_node, user_content: user_content)
        end

        child_lane = root_node.lane
        child_lane.update!(attachable: child)
        Conversations::LaneMemoryPromotionService.promote_for_branch!(conversation: self, lane: source_lane)
        snapshot_child_conversation_memory!(parent: self, child: child)
        snapshot_lane_state!(source_lane: source_lane, target_lane: child_lane)
        if root_node.node_type.to_s == Messages::UserMessage.node_type_key && user_content.to_s.strip.present?
          child.bootstrap_lane_first_user_message_node_id = root_node.id
        end
      end

      child
    end
  end

  def regenerate!(agent_node_id:)
    with_dag_errors_wrapped do
      graph = root_graph
      lane = chat_lane

      target = graph.nodes.active.find(agent_node_id)
      raise ArgumentError, "not an agent node" unless target.node_type == Messages::AgentMessage.node_type_key
      raise ArgumentError, "wrong lane" unless target.lane_id.to_s == lane.id.to_s
      regenerate_action = action_entry_for(target, "regenerate")
      raise Cybros::Error, "cannot regenerate deleted node" if regenerate_action["reason"].to_s == "deleted"
      raise Cybros::Error, "cannot regenerate non-terminal agent" if regenerate_action["reason"].to_s == "not_terminal"
      raise Cybros::Error, "cannot regenerate unfinished agent" if regenerate_action["reason"].to_s == "not_finished"

      latest_agent = latest_agent_message_for_lane(graph: graph, lane: lane)
      if target.id.to_s != latest_agent&.id&.to_s
        branch_action = action_entry_for(target, "branch")
        raise Cybros::Error, "agent is not rerunnable" unless branch_action.fetch("available", false)

        child = create_child!(from_node_id: target.id, kind: "branch", title: "Branch", user_content: "")
        return { mode: :branched, conversation: child }
      end

      raise Cybros::Error, "agent is not rerunnable" unless regenerate_action.fetch("available", false)

      archive_leaf_terminal_sidecars!(graph: graph, node: target)
      target.reload
      new_agent = target.rerun!(metadata_patch: { "generated_by" => "regenerate" })

      reset_turn_internal_execution!(
        graph: graph,
        turn_id: target.turn_id,
        preserve_node_ids: [new_agent.id, *turn_user_node_ids(graph: graph, turn_id: target.turn_id)],
        compressed_by_id: new_agent.id,
        reason: "turn_reset",
      )

      if enqueue_conversation_run!(
           agent_node: new_agent,
           selected_model_ref: new_agent.metadata.dig("llm", "model_ref"),
           user_input: "",
           debug: {},
           error: {},
         )
        graph.kick!
      end

      { mode: :in_place, node: new_agent }
    end
  end

  def select_swipe!(agent_node_id:, direction: nil, position: nil)
    with_dag_errors_wrapped do
      graph = root_graph
      lane = chat_lane

      node = graph.nodes.active.find(agent_node_id)
      raise ArgumentError, "not an agent node" unless node.node_type == Messages::AgentMessage.node_type_key
      raise ArgumentError, "wrong lane" unless node.lane_id.to_s == lane.id.to_s
      raise Cybros::Error, "cannot swipe deleted node" if node.deleted?

      version_set_id = node.version_set_id
      raise Cybros::Error, "missing version_set_id" if version_set_id.blank?

      in_flight =
        graph.nodes.active
          .where(version_set_id: version_set_id)
          .where(state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL])
          .exists?
      raise Cybros::Error, "cannot swipe while a version is in-flight" if in_flight

      all_versions = node.versions(include_inactive: true).to_a
      versions = swipeable_versions_for(node)
      raise ArgumentError, "no versions" if versions.empty?

      active_idx = versions.index { |v| v.id.to_s == node.id.to_s }
      raise Cybros::Error, "missing active version" if active_idx.nil?

      target_idx =
        if !position.nil?
          raw = position.to_s
          if AgentCore::Utils.uuid_like?(raw)
            candidate = all_versions.find { |v| v.id.to_s == raw }
            raise ArgumentError, "unknown version_id" if candidate.nil?
            raise Cybros::Error, "cannot swipe deleted version" if candidate.deleted?
            raise Cybros::Error, "target version must be finished" unless candidate.state == DAG::Node::FINISHED

            idx = versions.index { |v| v.id.to_s == raw }
            raise ArgumentError, "unknown version_id" if idx.nil?
            idx
          else
            n = Integer(raw, exception: false)
            raise ArgumentError, "position must be an integer or uuid" if n.nil?
            raise ArgumentError, "position must be >= 1" if n < 1
            raise ArgumentError, "position out of range" if n > versions.length
            n - 1
          end
        else
          dir = direction.to_s
          raise ArgumentError, "direction or position required" if dir.blank?

          case dir
          when "left"
            [active_idx - 1, 0].max
          when "right"
            [active_idx + 1, versions.length - 1].min
          else
            raise ArgumentError, "invalid direction"
          end
        end

      target_idx = [[target_idx, 0].max, versions.length - 1].min
      target = versions.fetch(target_idx)
      raise Cybros::Error, "cannot swipe deleted version" if target.deleted?

      raise Cybros::Error, "target version must be finished" unless target.state == DAG::Node::FINISHED

      archive_leaf_terminal_sidecars!(graph: graph, node: target)
      archive_leaf_terminal_sidecars!(graph: graph, node: node)
      adopted = target.adopt_version!
      adopted.reload
    end
  end

  def exclude_node!(node_id:)
    with_dag_errors_wrapped do
      node = root_graph.nodes.active.find(node_id)
      raise ActiveRecord::RecordNotFound unless node.lane_id.to_s == chat_lane.id.to_s
      if node.can_exclude_from_context?
        node.exclude_from_context!
      else
        node.request_exclude_from_context!
      end
      node
    end
  end

  def include_node!(node_id:)
    with_dag_errors_wrapped do
      node = root_graph.nodes.active.find(node_id)
      raise ActiveRecord::RecordNotFound unless node.lane_id.to_s == chat_lane.id.to_s
      if node.can_include_in_context?
        node.include_in_context!
      else
        node.request_include_in_context!
      end
      node
    end
  end

  def soft_delete_node!(node_id:)
    with_dag_errors_wrapped do
      graph = root_graph
      lane = chat_lane

      node = graph.nodes.active.find(node_id)
      raise ActiveRecord::RecordNotFound unless node.lane_id.to_s == lane.id.to_s

    body = node.body
    unless body&.deletable?
      raise Cybros::Error, "node type is not deletable: #{node.node_type}"
    end

    if fork_point_node?(node)
      raise Cybros::Error, "node is a fork point for another conversation and cannot be deleted"
    end

    # Stop first so we can apply strict visibility changes immediately when the graph is idle.
    stop_node_if_needed!(node)

    head = head_leaf_for_lane(graph: graph, lane: lane)
    if head
      trigger_node_id =
        graph.edges.active
          .where(edge_type: DAG::Edge::SEQUENCE, to_node_id: head.id)
          .order(:id)
          .pick(:from_node_id)

      rollback_needed = (node.id.to_s == head.id.to_s) || (trigger_node_id.present? && node.id.to_s == trigger_node_id.to_s)

      if rollback_needed
        # Stop/cancel the currently active downstream work starting from the head.
        descendant_ids = head.causal_descendant_ids.map(&:to_s)
        graph.nodes.active
          .where(id: descendant_ids)
          .where(lane_id: lane.id)
          .where(state: [DAG::Node::PENDING, DAG::Node::AWAITING_APPROVAL, DAG::Node::RUNNING])
          .find_each do |downstream|
            stop_node_if_needed!(downstream)
            cancel_runs_for_node!(downstream)
          end
      end
    end

    node.reload
    if node.can_soft_delete?
      node.soft_delete!
    else
      node.request_soft_delete!
    end

      cancel_runs_for_node!(node)
      node
    end
  end

  def restore_node!(node_id:)
    with_dag_errors_wrapped do
      node = root_graph.nodes.active.find(node_id)
      raise ActiveRecord::RecordNotFound unless node.lane_id.to_s == chat_lane.id.to_s
      if node.can_restore?
        node.restore!
      else
        node.request_restore!
      end
      node
    end
  end

  def translate!(node_id:, target_lang:)
    with_dag_errors_wrapped do
      target_lang = target_lang.to_s.strip
      raise ArgumentError, "target_lang required" if target_lang.blank?

      node = root_graph.nodes.active.find(node_id)
      raise ActiveRecord::RecordNotFound unless node.lane_id.to_s == chat_lane.id.to_s

      graph = root_graph
      graph.with_graph_lock! do
        node.reload
        meta = node.metadata.is_a?(Hash) ? node.metadata.deep_stringify_keys : {}
        i18n = meta["i18n"].is_a?(Hash) ? meta["i18n"] : {}
        pending = i18n["translation_pending"].is_a?(Hash) ? i18n["translation_pending"] : {}
        pending[target_lang] = true
        i18n["translation_pending"] = pending
        meta["i18n"] = i18n
        node.update!(metadata: meta)
      end

      node
    end
  end

  def clear_translations!
    with_dag_errors_wrapped do
      graph = root_graph
      lane_id = chat_lane.id

      graph.with_graph_lock! do
        graph.nodes.active.where(lane_id: lane_id).find_each do |node|
          meta = node.metadata.is_a?(Hash) ? node.metadata.deep_stringify_keys : {}
          next unless meta.key?("i18n")

          i18n = meta["i18n"].is_a?(Hash) ? meta["i18n"] : {}
          i18n.delete("translation_pending")
          i18n.delete("translations")
          i18n.delete("translation_errors")

          if i18n.empty?
            meta.delete("i18n")
          else
            meta["i18n"] = i18n
          end

          node.update!(metadata: meta)
        end
      end

      true
    end
  end

  def merge_into_parent!(metadata: {})
    raise Cybros::Error, "merge_into_parent! only valid for non-root conversations" if root?

    with_dag_errors_wrapped do
      parent = parent_conversation || raise(Cybros::Error, "missing parent_conversation")
      graph = root_graph

      source_lane = chat_lane
      target_lane = parent.chat_lane

      target_head = head_leaf_for_lane(graph: graph, lane: target_lane, node_type: Messages::AgentMessage.node_type_key)
      source_head = head_leaf_for_lane(graph: graph, lane: source_lane, node_type: Messages::AgentMessage.node_type_key)
      raise Cybros::Error, "missing target head" if target_head.nil?
      raise Cybros::Error, "missing source head" if source_head.nil?

      merge_node = nil
      graph.mutate! do |m|
        merge_metadata = metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}
        source_snapshot = lane_state_snapshot(lane: source_lane)
        target_snapshot = lane_state_snapshot(lane: target_lane)
        arguments = {
          "target_lane_id" => target_lane.id,
          "source_lane_ids" => [source_lane.id],
          "target_lane_kv_snapshot" => target_snapshot.fetch("kv_entries"),
          "source_lane_kv_snapshots" => [{ "lane_id" => source_lane.id, "entries" => source_snapshot.fetch("kv_entries") }],
          "target_prompt_buffer_snapshot" => target_snapshot.fetch("prompt_buffer_entries"),
          "source_prompt_buffer_snapshots" => [{ "lane_id" => source_lane.id, "entries" => source_snapshot.fetch("prompt_buffer_entries") }],
          "merge_metadata" => merge_metadata,
          "archive_source_lanes" => merge_metadata.delete("archive_source_lanes") == true,
        }
        merge_node =
          m.merge_lanes!(
            target_lane: target_lane,
            target_from_node: target_head,
            source_lanes_and_nodes: [{ lane: source_lane, from_node: source_head }],
            node_type: Messages::Task.node_type_key,
            metadata: merge_metadata,
            body_input: merge_task_body_input(arguments: arguments),
          )
      end

      merge_node
    end
  end

  # Product-level API: returns the best-effort “current chat head” leaf for this
  # conversation’s chat lane, accounting for swipe selection and visibility.
  def chat_head_leaf(node_type: nil)
    head_leaf_for_lane(graph: root_graph, lane: chat_lane, node_type: node_type)
  end

  def chat_head_node_id(node_type: nil)
    chat_head_leaf(node_type: node_type)&.id&.to_s
  end

  def chat_lane
    if root?
      lane = dag_graph.main_lane
      if lane.attachable.nil?
        lane.update!(attachable: self)
      elsif lane.attachable != self
        raise Cybros::Error, "main lane is already attached to a different model"
      end
      lane
    else
      lane = dag_lane
      if lane.nil? && association(:dag_lane).loaded?
        association(:dag_lane).reset
        lane = dag_lane
      end

      lane || raise(Cybros::Error, "branch conversation is missing dag_lane")
    end
  end

  private

    def swipeable_versions_for(node)
      node.versions(include_inactive: true).select do |candidate|
        candidate.state == DAG::Node::FINISHED && !candidate.deleted?
      end
    end

    def normalize_runtime_settings
      self.permission_mode = permission_mode.to_s.strip.presence || "default"
      self.agent_config = self[:agent_config].is_a?(Hash) ? self[:agent_config].deep_stringify_keys : {}
      self.composer_draft = normalized_composer_draft_payload(self[:composer_draft])
    end

    def metadata_model_ref
      raw_metadata = self[:metadata]
      return nil unless raw_metadata.is_a?(Hash)

      value = raw_metadata.dig("llm", "model_ref").to_s.strip
      value.presence
    end

    def normalized_composer_draft_payload(value)
      raw = value.is_a?(Hash) ? value.deep_stringify_keys : {}
      draft = {}

      content = raw["content"]
      draft["content"] = content.to_s if content.is_a?(String) || content.is_a?(Numeric)

      model_ref = raw["model_ref"].to_s.strip
      draft["model_ref"] = model_ref if model_ref.present?

      draft_permission_mode = raw["permission_mode"].to_s.strip
      draft["permission_mode"] = draft_permission_mode if draft_permission_mode.present?

      updated_at = raw["updated_at"].to_s.strip
      draft["updated_at"] = updated_at if updated_at.present?

      draft
    end

    def parse_composer_draft_timestamp(value)
      raw = value.to_s.strip
      return nil if raw.blank?

      Time.iso8601(raw)
    rescue ArgumentError
      nil
    end

    def dispatch_bootstrap_hooks_after_commit
      Conversations::BootstrapHookDispatcher.dispatch_created!(conversation: self)

      lane_first_user_message_node_id = bootstrap_lane_first_user_message_node_id.to_s.presence
      return if lane_first_user_message_node_id.blank?

      user_node = root_graph.nodes.active.find_by(id: lane_first_user_message_node_id)
      return if user_node.nil?

      Conversations::BootstrapHookDispatcher.dispatch_lane_first_user_message!(
        conversation: self,
        user_node: user_node,
      )
    end

    def assign_default_agent
      return if agent.present?

      selected_agent = Agents::BootstrapBundledDefaultService.ensure_agent!
      self.agent = selected_agent
      self.agent_config_schema_fingerprint ||= selected_agent.config_schema_fingerprint
    end

    def enqueue_conversation_run!(agent_node:, selected_model_ref:, permission_mode: nil, user_input:, debug:, error:)
      result =
        RunDrafts::ConversationTurnOrchestrator.enqueue!(
          conversation: self,
          initiated_by_user: user,
          selected_model_ref: selected_model_ref.to_s,
          permission_mode: permission_mode.to_s,
          trigger_snapshot: {
            "kind" => "user_turn",
            "dag_node_id" => agent_node.id,
            "user_input" => user_input.to_s,
          },
          debug: debug,
          error: error,
        )
      result.fetch(:conversation_run).present?
    end

    def turn_execution_projector
      @turn_execution_projector ||= Conversation::TurnExecutionProjector.new(conversation: self)
    end

  public

    def turn_execution_for_turn_id(turn_id)
      turn_execution_projector.turn_execution_for_turn_id(turn_id)
    end

    def turn_execution_for_node_id(node_id)
      node = find_chat_lane_node!(node_id)
      turn_execution_projector.turn_execution_for_turn_id(node.turn_id)
    end

  private

    def transcript_projection
      DAG::TranscriptProjection.new(
        graph: root_graph,
        context_node_decorator:
          lambda do |message|
            decorate_message(message)
          end,
      )
    end

    def decorate_message_page(page)
      out = page.deep_dup
      out["messages"] = filter_queued_turn_messages(decorate_messages(out.fetch("messages", [])))
      out
    end

    def execution_event_scope_for_node(node)
      output_scope =
        root_graph.node_events.where(
          node_id: node.id,
          kind: [DAG::NodeEvent::OUTPUT_DELTA, DAG::NodeEvent::OUTPUT_COMPACTED],
        )

      task_node_ids =
        root_graph.nodes.active
          .where(
            lane_id: node.lane_id,
            turn_id: node.turn_id,
            node_type: Messages::Task.node_type_key,
          )
          .pluck(:id)

      return output_scope if task_node_ids.empty?

      activity_scope =
        root_graph.node_events.where(
          node_id: task_node_ids,
          kind: DAG::NodeEvent::ACTIVITY_EVENT_KINDS,
        )

      output_scope.or(activity_scope)
    end

    def fork_child_root_node!(mutations:, from_node:, user_content:)
      seeded_user_content = user_content.to_s.strip

      if from_node.node_type.to_s == Messages::AgentMessage.node_type_key && seeded_user_content.blank?
        snapshot_metadata = from_node.metadata.is_a?(Hash) ? from_node.metadata.deep_dup : {}
        snapshot_metadata.except!("usage", "output_stats", "timing", "worker", "error", "reason")
        snapshot_metadata["generated_by"] = "branch_snapshot"
        snapshot_metadata["forked_from_node_id"] = from_node.id.to_s

        return mutations.fork_from!(
          from_node: from_node,
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          body_input: from_node.body_input.deep_dup,
          body_output: from_node.body_output.deep_dup,
          metadata: snapshot_metadata,
        )
      end

      mutations.fork_from!(
        from_node: from_node,
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        content: seeded_user_content,
        metadata: {},
      )
    end

    def snapshot_lane_state!(source_lane:, target_lane:)
      apply_lane_state_snapshot!(lane: target_lane, snapshot: lane_state_snapshot(lane: source_lane))
    end

    def snapshot_child_conversation_memory!(parent:, child:)
      Conversations::BranchMemorySnapshot.snapshot!(parent: parent, child: child)
    end

    def lane_state_snapshot(lane: chat_lane)
      {
        "kv_entries" =>
          lane.lane_kv_entries.order(:key, :id).map do |entry|
            {
              "key" => entry.key,
              "value" => snapshot_json(entry.value),
              "written_by_type" => entry.written_by_type,
              "written_by_id" => entry.written_by_id,
            }
          end,
        "prompt_buffer_entries" =>
          lane.lane_prompt_buffer_entries.ordered.reject { |entry| entry.buffer_name == "system" }.map do |entry|
            {
              "buffer_name" => entry.buffer_name,
              "seq" => entry.seq,
              "kind" => entry.kind,
              "content" => entry.content,
              "priority" => entry.priority,
              "estimated_tokens" => entry.estimated_tokens,
              "metadata" => snapshot_json(entry.metadata),
            }
          end,
      }
    end

    def apply_lane_state_snapshot!(lane:, snapshot:)
      snapshot = snapshot.is_a?(Hash) ? snapshot.deep_stringify_keys : {}

      Array(snapshot["kv_entries"]).each do |entry|
        next unless entry.is_a?(Hash)

        lane.lane_kv_entries.create!(
          key: entry["key"],
          value: snapshot_json(entry["value"]),
          written_by_type: entry["written_by_type"],
          written_by_id: entry["written_by_id"],
        )
      end

      Array(snapshot["prompt_buffer_entries"]).each do |entry|
        next unless entry.is_a?(Hash)

        lane.lane_prompt_buffer_entries.create!(
          buffer_name: entry["buffer_name"],
          seq: entry["seq"],
          kind: entry["kind"],
          content: entry["content"],
          priority: entry["priority"],
          estimated_tokens: entry["estimated_tokens"],
          metadata: snapshot_json(entry["metadata"]),
        )
      end
    end

    def snapshot_json(value)
      case value
      when Hash
        value.deep_dup
      when Array
        value.map { |element| snapshot_json(element) }
      else
        value
      end
    end

    def merge_task_body_input(arguments:)
      {
        "tool_call_id" => "merge_lane_state:#{arguments.fetch("source_lane_ids").join(",")}",
        "requested_name" => "merge_lane_state",
        "name" => "merge_lane_state",
        "arguments" => snapshot_json(arguments),
        "arguments_summary" => AgentCore::Utils.truncate_utf8_bytes(JSON.generate(arguments), max_bytes: 4_000),
        "source" => "conversation_merge",
      }
    end

    def decorate_transcript_page(page)
      out = page.deep_dup
      out["transcript"] = decorate_messages(out.fetch("transcript", []))
      out
    end

    def decorate_messages(messages)
      messages = Array(messages)
      node_ids = messages.filter_map { |message| message.is_a?(Hash) ? message["node_id"].to_s.presence : nil }
      attachment_ids =
        messages.flat_map do |message|
          next [] unless message.is_a?(Hash)

          Array(message.dig("payload", "input", "attachments")).filter_map do |attachment|
            attachment.is_a?(Hash) ? attachment["id"].to_s.presence : nil
          end
        end
      nodes_by_id = root_graph.nodes.where(id: node_ids).includes(:body).to_a.index_by { |node| node.id.to_s }
      attachments_by_id =
        conversation_attachments
          .where(id: attachment_ids)
          .includes(file_attachment: :blob)
          .to_a
          .index_by { |attachment| attachment.id.to_s }

      messages.map { |message| decorate_message(message, nodes_by_id: nodes_by_id, attachments_by_id: attachments_by_id) }
    end

    def filter_queued_turn_messages(messages, now: Time.current)
      hidden_node_ids =
        queued_turn_items(now: now).flat_map do |item|
          [item["user_node_id"].to_s.presence, item["agent_node_id"].to_s.presence]
        end.compact
      return messages if hidden_node_ids.empty?

      Array(messages).reject do |message|
        hidden_node_ids.include?(message.is_a?(Hash) ? message["node_id"].to_s : nil)
      end
    end

    def decorate_message(message, nodes_by_id: nil, attachments_by_id: {})
      return message unless message.is_a?(Hash)

      out = message.deep_dup
      node_id = out["node_id"].to_s
      return out if node_id.blank?

      node = nodes_by_id ? nodes_by_id[node_id] : root_graph.nodes.find_by(id: node_id)
      return out if node.nil?

      out["action_policy"] = action_policy_for(node)
      out["run_state"] = turn_execution_projector.run_state_for_node_id(node.id)
      decorate_input_attachments!(out, attachments_by_id: attachments_by_id)
      out
    end

    def decorate_input_attachments!(message, attachments_by_id:)
      payload = message["payload"]
      return unless payload.is_a?(Hash)

      input = payload["input"]
      return unless input.is_a?(Hash)

      attachments = Array(input["attachments"]).select { |entry| entry.is_a?(Hash) }
      return if attachments.empty?

      input["attachments"] =
        attachments.map do |entry|
          decorate_input_attachment(entry, attachments_by_id: attachments_by_id)
        end
    end

    def decorate_input_attachment(entry, attachments_by_id:)
      out = entry.deep_dup
      attachment = attachments_by_id[out["id"].to_s]
      return out if attachment.nil? || !attachment.file.attached?

      out["image"] = attachment.image?
      out["download_path"] = Rails.application.routes.url_helpers.rails_storage_proxy_url(attachment.file, only_path: true, disposition: :attachment)
      out["byte_size"] = attachment.byte_size
      out["content_type"] = attachment.content_type
      out["filename"] = attachment.filename

      if attachment.image?
        preview_path = attachment_preview_path(attachment)
        out["preview_path"] = preview_path if preview_path.present?
      end

      out
    end

    def attachment_preview_path(attachment)
      representation = attachment.prompt_image_representation
      return nil if representation.nil?

      Rails.application.routes.url_helpers.rails_storage_proxy_url(representation.processed, only_path: true)
    rescue StandardError
      nil
    end

    def normalize_uploaded_attachments(value)
      Array(value).flatten.compact.select { |upload| upload.respond_to?(:original_filename) }
    end

    def validate_attachment_constraints!(uploaded_attachments)
      return if uploaded_attachments.empty?

      if uploaded_attachments.length > MAX_ATTACHMENTS_PER_MESSAGE
        raise ArgumentError, "A maximum of #{MAX_ATTACHMENTS_PER_MESSAGE} attachments can be uploaded per message."
      end

      if uploaded_attachments.any? { |upload| uploaded_attachment_byte_size(upload) > MAX_ATTACHMENT_BYTES }
        raise ArgumentError, "Attachments must be 25 MB or smaller."
      end
    end

    def validate_attachment_support!(uploaded_attachments)
      return if uploaded_attachments.empty?
      return if agent&.supports_conversation_attachments?

      raise ArgumentError, "Selected agent does not support file attachments."
    end

    def persist_message_attachments!(user_node:, uploaded_attachments:)
      uploaded_attachments.each_with_index do |uploaded_attachment, index|
        attachment =
          conversation_attachments.build(
            source_message_node_id: user_node.id,
            position: index + 1,
            sha256_digest: uploaded_attachment_digest(uploaded_attachment),
          )
        attachment.file.attach(
          io: uploaded_attachment_io(uploaded_attachment),
          filename: uploaded_attachment_filename(uploaded_attachment),
          content_type: uploaded_attachment_content_type(uploaded_attachment),
        )
        attachment.save!
      end

      Conversations::AttachmentManifestBuilder.build(
        conversation: self,
        source_message_node_id: user_node.id,
      )
    end

    def annotate_user_message_attachments!(user_node:, attachments_manifest:)
      body = user_node.body
      body_input = body.input.is_a?(Hash) ? body.input.deep_dup : {}
      body_input["attachments"] = Array(attachments_manifest)
      body.update!(input: body_input)
    end

    def uploaded_attachment_io(uploaded_attachment)
      io =
        if uploaded_attachment.respond_to?(:tempfile) && uploaded_attachment.tempfile.present?
          uploaded_attachment.tempfile
        else
          uploaded_attachment
        end
      io.rewind if io.respond_to?(:rewind)
      io
    end

    def uploaded_attachment_filename(uploaded_attachment)
      uploaded_attachment.original_filename.to_s.presence || "attachment"
    end

    def uploaded_attachment_content_type(uploaded_attachment)
      uploaded_attachment.content_type.to_s.presence || "application/octet-stream"
    end

    def uploaded_attachment_digest(uploaded_attachment)
      io = uploaded_attachment_io(uploaded_attachment)
      digest = Digest::SHA256.new
      digest << io.read
      io.rewind if io.respond_to?(:rewind)
      digest.hexdigest
    end

    def uploaded_attachment_byte_size(uploaded_attachment)
      size = uploaded_attachment.size if uploaded_attachment.respond_to?(:size)
      return size.to_i if size.present?

      io = uploaded_attachment_io(uploaded_attachment)
      size = io.size if io.respond_to?(:size)
      return size.to_i if size.present?

      io.read.to_s.bytesize
    ensure
      io&.rewind if io&.respond_to?(:rewind)
    end

    def normalize_turn_execution_diagnostic_level(value)
      value.to_s == "debug" ? "debug" : "standard"
    end

    def turn_execution_debug_payload(diagnostic_level)
      {
        "turn_execution" => {
          "diagnostic_level" => normalize_turn_execution_diagnostic_level(diagnostic_level),
        },
      }
    end

    def apply_turn_execution_diagnostic_level!(node, diagnostic_level:)
      metadata = node.metadata.is_a?(Hash) ? node.metadata.deep_dup : {}
      metadata["turn_execution"] = {
        "diagnostic_level" => normalize_turn_execution_diagnostic_level(diagnostic_level),
      }
      node.update!(metadata: metadata)
    end

    def action_entry_for(node, action_key)
      action_policy_for(node).fetch("actions").fetch(action_key.to_s)
    end

    def find_chat_lane_node!(node_id)
      node = root_graph.nodes.find_by(id: node_id.to_s)
      raise ActiveRecord::RecordNotFound if node.nil?
      raise ActiveRecord::RecordNotFound unless node.lane_id.to_s == chat_lane.id.to_s

      node
    end

    def node_stoppable?(node)
      [DAG::Node::PENDING, DAG::Node::AWAITING_APPROVAL, DAG::Node::RUNNING].include?(node.state)
    end

    def parked_run_draft_for_node!(node_id)
      draft =
        run_drafts
          .where(status: RunDrafts::ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS)
          .where("trigger_snapshot ->> 'dag_node_id' = ?", node_id.to_s)
          .order(created_at: :desc)
          .first
      if draft.present? && draft.expires_at.present? && draft.expires_at <= Time.current
        RunDrafts::ApprovalExpiryService.expire!(draft: draft)
        raise Cybros::Error, "state_changed"
      end
      return draft if draft.present?

      raise Cybros::Error, "state_changed"
    end

    def cancel_parked_approval!(draft:, reason:)
      draft.update!(
        approval_state:
          draft.approval_state.merge(
            "status" => "canceled",
            "reason" => reason.to_s,
            "canceled_at" => Time.current.iso8601,
          ),
      )
      RunDrafts::DiscardService.discard!(draft: draft, status: "discarded")
    end

    def startable_pending_agent?(node:)
      return false unless node.node_type.to_s == Messages::AgentMessage.node_type_key
      return false unless node.state == DAG::Node::PENDING
      return false if node.compressed_at.present? || node.deleted?
      return false if node.claimed_at.present? || node.started_at.present?
      return false unless node.lane_id.to_s == chat_lane.id.to_s
      return false unless pending_agent_leaf_position_valid?(graph: root_graph, lane: chat_lane, agent_node: node)
      return false if latest_executing_agent_for_lane(graph: root_graph, lane: chat_lane).present?

      true
    end

    def with_dag_errors_wrapped
      yield
    rescue DAG::Error => e
      raise Cybros::Error, e.message
    end

    def assert_mutation_allowed_for_managed_subagent!
      return unless managed_subagent_read_only?

      raise Cybros::Error, "managed_subagent_read_only"
    end

    def root_conversation!
      root_conversation || raise(Cybros::Error, "conversation is missing root_conversation")
    end

    def assign_root_conversation
      return if root_conversation_id.present?

      if parent_conversation
        self.root_conversation = parent_conversation.root_conversation || parent_conversation
      end
    end

    def set_root_conversation_to_self
      return if root_conversation_id.present?

      update_column(:root_conversation_id, id)
    end

    def ensure_statistics_sample_origin
      base_metadata = metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}
      statistics = base_metadata["statistics"].is_a?(Hash) ? base_metadata["statistics"].deep_stringify_keys : {}
      statistics["sample_origin"] = self.class.normalize_statistics_sample_origin(statistics["sample_origin"])
      self.metadata = base_metadata.merge("statistics" => statistics)
    end

    def cancel_runs_for_node!(node)
      scope = ConversationRun.where(conversation_id: id, dag_node_id: node.id).order(:id)
      run = scope.last
      return if run.nil?
      return if run.canceled? || run.succeeded? || run.failed?

      cancel_execution_capacity_wait!(run)

      if run.running?
        begin
          node.stop!(reason: "soft_deleted")
        rescue StandardError
          nil
        end
      end

      if node.terminal?
        ConversationRunTracker.mark_terminal_for_node!(node, at: node.finished_at || Time.current)
      else
        run.mark_canceled!
      end
    end

    def cancel_execution_capacity_wait!(run)
      capacity = run.execution_capacity_snapshot
      return unless capacity.is_a?(Hash)

      scope_type = capacity["scope_type"]
      scope_id = capacity["scope_id"]
      return if scope_type.blank? || scope_id.blank?

      RuntimeGovernance::RuntimeWaits.cancel!(
        owner_type: run.class.name,
        owner_id: run.id,
        reason_type: "execution_capacity",
        subject_type: scope_type,
        subject_id: scope_id,
      )
    end

    def rewrite_queued_turns!(selected_user_node_id:, mode:, model_ref: nil, interrupted_output_policy_override: nil)
      with_dag_errors_wrapped do
        selected_user_node_id = selected_user_node_id.to_s
        queued_items = queued_turn_items
        selected =
          queued_items.find do |item|
            item.fetch("user_node_id") == selected_user_node_id
          end
        raise ActiveRecord::RecordNotFound if selected.nil?

        remaining =
          queued_items.reject do |item|
            item.fetch("user_node_id") == selected_user_node_id
          end

        archive_queued_turns!(queued_items: queued_items, reason: "rewrite_queued_turns")

        if mode.to_sym == :steer
          steer_queued_turn_model_ref = model_ref.to_s.strip.presence || selected["model_ref"]
          steer_current_turn!(
            content: selected.fetch("content"),
            model_ref: steer_queued_turn_model_ref,
            interrupted_output_policy_override: interrupted_output_policy_override,
          )
        end

        remaining.each do |item|
          append_user_message!(
            content: item.fetch("content"),
            model_ref: item["model_ref"],
            input_policy_override: rewrite_queue_input_policy_override,
            repair_pending_tail: false,
          )
        end

        selected
      end
    end

    def archive_queued_turns!(queued_items:, reason:)
      graph = root_graph
      lane = chat_lane

      graph.with_graph_lock! do
        running_agent = latest_executing_agent_for_lane(graph: graph, lane: lane)
        raise Cybros::Error, "no_running_turn" if running_agent.nil?

        now = Time.current

        queued_items.each do |item|
          turn_nodes =
            graph.nodes.active
              .where(lane_id: lane.id, turn_id: item.fetch("turn_id"))
              .order(:id)
              .to_a
          next if turn_nodes.empty?

          turn_nodes.each do |node|
            stop_node_if_needed!(node, reason: reason)
            cancel_runs_for_node!(node)
          end

          archive_turn_bundle!(
            graph: graph,
            turn_nodes: turn_nodes,
            compressed_by_id: running_agent.id,
            now: now,
          )
        end
      end
    end

    def archive_turn_bundle!(graph:, turn_nodes:, compressed_by_id:, now:)
      return if turn_nodes.empty?

      node_ids = turn_nodes.map(&:id)
      lane_id = turn_nodes.first.lane_id
      turn_id = turn_nodes.first.turn_id

      edge_ids =
        graph.edges.active
          .where("from_node_id IN (?) OR to_node_id IN (?)", node_ids, node_ids)
          .pluck(:id)

      graph.nodes.where(id: node_ids).update_all(
        compressed_at: now,
        compressed_by_id: compressed_by_id,
        updated_at: now,
      )

      if edge_ids.any?
        graph.edges.where(id: edge_ids).update_all(compressed_at: now, updated_at: now)
      end

      DAG::TurnHeadMaintenance.refresh_for_turn_ids!(
        graph: graph,
        lane_id: lane_id,
        turn_ids: [turn_id],
      )
    end

    def rewrite_queue_input_policy_override
      {
        "running_input_policy" => "queue",
        "input_coalescing" => {
          "enabled" => false,
        },
      }
    end

    def stop_node_if_needed!(node, reason: "soft_deleted")
      return if node.terminal?

      begin
        node.stop!(reason: reason)
      rescue StandardError
        nil
      end
    end

    def fork_point_node?(node)
      root_id = (root_conversation || self).id
      Conversation.where(root_conversation_id: root_id, forked_from_node_id: node.id).exists?
    end

    def head_leaf_for_lane(graph:, lane:, node_type: nil)
      lane_nodes = graph.nodes.active.where(lane_id: lane.id)
      lane_blocking_edges =
        graph.edges.active
          .where(edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)
          .where(from_node_id: lane_nodes.select(:id), to_node_id: lane_nodes.select(:id))

      scope = lane_nodes.where.not(id: lane_blocking_edges.select(:from_node_id))
      scope = scope.where(node_type: node_type.to_s) if node_type.present?

      visible_scope = scope.where(context_excluded_at: nil, deleted_at: nil)

      visible = visible_scope.order(:id).last
      return visible if visible

      scope.order(:id).last
    end

    def latest_agent_message_for_lane(graph:, lane:)
      graph.nodes.active
        .where(lane_id: lane.id, node_type: Messages::AgentMessage.node_type_key, deleted_at: nil)
        .order(:id)
        .last
    end

    def leaf_terminal_sidecars_for(graph:, node:)
      child_ids =
        graph.edges.active
          .where(from_node_id: node.id, edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)
          .pluck(:to_node_id)
      return [] if child_ids.empty?

      children = graph.nodes.active.where(id: child_ids).order(:id).to_a
      return nil unless children.size == child_ids.size
      return nil unless children.all? { |child| graph.leaf_terminal?(child) }

      children
    end

    def latest_agent_rerunnable_in_place?(graph:, lane:, node:)
      latest_agent = latest_agent_message_for_lane(graph: graph, lane: lane)
      return false unless latest_agent&.id.to_s == node.id.to_s

      !leaf_terminal_sidecars_for(graph: graph, node: node).nil?
    end

    def archive_leaf_terminal_sidecars!(graph:, node:)
      sidecars = leaf_terminal_sidecars_for(graph: graph, node: node)
      return if sidecars.blank?

      now = Time.current
      sidecar_ids = sidecars.map(&:id)
      edge_ids =
        graph.edges.active
          .where(from_node_id: node.id, to_node_id: sidecar_ids)
          .pluck(:id)

      graph.nodes.where(id: sidecar_ids).update_all(
        context_excluded_at: now,
        deleted_at: now,
        compressed_at: now,
        compressed_by_id: node.id,
        updated_at: now,
      )
      graph.edges.where(id: edge_ids).update_all(compressed_at: now, updated_at: now) if edge_ids.any?
    end

    def reset_turn_internal_execution!(graph:, turn_id:, preserve_node_ids:, compressed_by_id:, reason:)
      preserve_ids = Array(preserve_node_ids).compact.map(&:to_s)
      now = Time.current
      candidate_ids = []

      graph.with_graph_lock! do
        queue_scope = turn_internal_tasks.nonterminal.where(turn_id: turn_id)
        queue_scope.update_all(
          status: "canceled",
          canceled_reason: reason,
          updated_at: now,
        ) if queue_scope.exists?

        candidate_ids =
          graph.nodes.active
            .where(turn_id: turn_id)
            .where.not(id: preserve_ids)
            .where.not(node_type: Messages::UserMessage.node_type_key)
            .pluck(:id)
      end

      graph.nodes.where(id: candidate_ids).find_each do |node|
        stop_node_if_needed!(node, reason: reason)
        cancel_runs_for_node!(node)
      end

      graph.with_graph_lock! do
        next unless candidate_ids.any?

        graph.nodes.active.where(id: candidate_ids).update_all(
          compressed_at: now,
          compressed_by_id: compressed_by_id,
          updated_at: now,
        )
        graph.edges.active.where(from_node_id: candidate_ids).or(
          graph.edges.active.where(to_node_id: candidate_ids)
        ).update_all(compressed_at: now, updated_at: now)
      end
    end

    def turn_user_node_ids(graph:, turn_id:)
      graph.nodes.active.where(turn_id: turn_id, node_type: Messages::UserMessage.node_type_key).pluck(:id)
    end

    def reanchor_turn_internal_tasks_for_retry!(turn_id:, from_node_id:, to_node_id:)
      turn_internal_tasks.where(turn_id: turn_id, source_node_id: from_node_id)
        .where.not(status: TurnInternalTask::TERMINAL_STATUSES)
        .where(materialized_task_node_id: nil)
        .update_all(source_node_id: to_node_id, updated_at: Time.current)
    end

    def queue_anchor_agent_for_lane(graph:, lane:)
      graph.nodes.active
        .where(
          lane_id: lane.id,
          node_type: Messages::AgentMessage.node_type_key,
          state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL],
        )
        .order(:id)
        .first
    end

    def resolve_model_ref!(requested_model_ref:)
      model_ref = requested_model_ref.to_s.strip.presence
      if model_ref
        Cybros::AgentRuntimeResolver.validate_model_ref!(model_ref: model_ref)
        self.metadata = (metadata || {}).deep_merge({ "llm" => { "model_ref" => model_ref } })
        save! if changed?
        return model_ref
      end

      saved_model_ref = metadata.dig("llm", "model_ref").to_s.strip.presence
      if saved_model_ref
        Cybros::AgentRuntimeResolver.validate_model_ref!(model_ref: saved_model_ref)
        return saved_model_ref
      end

      resolved_model_ref =
        Cybros::AgentRuntimeResolver.default_model_ref_for(
          agent_metadata: (metadata || {}).fetch("agent", {}),
          agent: agent,
        )

      self.metadata = (metadata || {}).deep_merge({ "llm" => { "model_ref" => resolved_model_ref } })
      save! if changed?
      resolved_model_ref
    end

    def coalescing_claim_after_at(policy:, now:)
      coalescing = policy.fetch("input_coalescing", {})
      return nil unless coalescing["enabled"]

      window_ms = Integer(coalescing["window_ms"], exception: false).to_i
      return nil if window_ms <= 0

      now + (window_ms / 1000.0)
    end

    def coalescible_turn_for_lane(graph:, lane:, now:)
      agent_node =
        graph.nodes.active
          .where(
            lane_id: lane.id,
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            claimed_at: nil,
            started_at: nil,
          )
          .order(:id)
          .last
      return nil if agent_node.nil?
      return nil if pending_agent_claimable_now?(graph: graph, agent_node: agent_node, now: now)

      user_node =
        graph.nodes.active
          .where(
            lane_id: lane.id,
            turn_id: agent_node.turn_id,
            node_type: Messages::UserMessage.node_type_key,
          )
          .order(:id)
          .last
      return nil if user_node.nil?

      { user_node: user_node, agent_node: agent_node }
    end

    def pending_agent_claimable_now?(graph:, agent_node:, now:)
      claim_after_at = agent_node.claim_after_at
      return false if claim_after_at.present? && claim_after_at > now

      pending_agent_dependencies_satisfied?(graph: graph, agent_node: agent_node)
    end

    def pending_agent_dependencies_satisfied?(graph:, agent_node:)
      return false unless agent_node.state == DAG::Node::PENDING
      return false if agent_node.compressed_at.present? || agent_node.deleted?

      graph.edges.active.where(to_node_id: agent_node.id, edge_type: [DAG::Edge::SEQUENCE, DAG::Edge::DEPENDENCY]).find_each do |edge|
        parent = graph.nodes.active.find_by(id: edge.from_node_id)
        next if parent.nil?

        case edge.edge_type
        when DAG::Edge::SEQUENCE
          return false unless parent.terminal?
        when DAG::Edge::DEPENDENCY
          return false unless parent.state == DAG::Node::FINISHED
        end
      end

      true
    end

    def repair_stale_pending_middle_agents!(graph:, lane:, now:)
      stale_pending_agents_for_lane(graph: graph, lane: lane).each do |agent_node|
        sequence_children = active_sequence_children_for_node(graph: graph, node: agent_node)
        next if sequence_children.empty?
        next if sequence_children.all? { |child| graph.leaf_terminal?(child) }

        stable_parent = stable_sequence_parent_for(node: agent_node)
        sequence_children.each do |child|
          ensure_active_sequence_edge!(graph: graph, from_node: stable_parent, to_node: child, now: now)
        end

        silently_archive_pending_agent_node!(graph: graph, node: agent_node, now: now)
      end
    end

    def repair_stale_tail_pending_agent!(graph:, lane:, now:)
      tail = head_leaf_for_lane(graph: graph, lane: lane)
      return nil unless silently_repairable_pending_agent?(tail)

      silently_archive_pending_agent_node!(graph: graph, node: tail, now: now)
      tail
    end

    def stale_pending_agents_for_lane(graph:, lane:)
      graph.nodes.active
        .where(
          lane_id: lane.id,
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          claimed_at: nil,
          started_at: nil,
        )
        .where(deleted_at: nil)
        .order(:id)
        .to_a
    end

    def silently_repairable_pending_agent?(node)
      return false unless node.is_a?(DAG::Node)
      return false unless node.node_type.to_s == Messages::AgentMessage.node_type_key
      return false unless node.state == DAG::Node::PENDING
      return false if node.compressed_at.present? || node.deleted?
      return false if node.claimed_at.present? || node.started_at.present?

      true
    end

    def active_sequence_children_for_node(graph:, node:)
      child_ids =
        graph.edges.active
          .where(from_node_id: node.id, edge_type: DAG::Edge::SEQUENCE)
          .order(:id)
          .pluck(:to_node_id)

      return [] if child_ids.empty?

      graph.nodes.active.where(id: child_ids).order(:id).to_a
    end

    def pending_agent_leaf_position_valid?(graph:, lane:, agent_node:)
      lane_leaves = graph.leaf_nodes.where(lane_id: lane.id).to_a
      return true if lane_leaves.empty?

      sidecar_leaves = lane_leaves.reject { |leaf| leaf.id == agent_node.id }
      return true if sidecar_leaves.empty?

      descendant_ids = agent_node.causal_descendant_ids
      sidecar_leaves.all? do |leaf|
        descendant_ids.include?(leaf.id) && graph.leaf_terminal?(leaf)
      end
    end

    def ensure_active_sequence_edge!(graph:, from_node:, to_node:, now:)
      return if from_node.nil? || to_node.nil?

      edge =
        graph.edges.find_by(
          from_node_id: from_node.id,
          to_node_id: to_node.id,
          edge_type: DAG::Edge::SEQUENCE,
        )

      return edge if edge.present? && edge.compressed_at.nil?

      if edge
        edge.update_columns(compressed_at: nil, updated_at: now)
        return edge
      end

      DAG::Mutations.new(graph: graph).create_edge(
        from_node: from_node,
        to_node: to_node,
        edge_type: DAG::Edge::SEQUENCE,
        metadata: { "generated_by" => "silent_pending_repair" },
      )
    end

    def silently_archive_pending_agent_node!(graph:, node:, now:)
      edge_ids =
        graph.edges.active
          .where("from_node_id = :node_id OR to_node_id = :node_id", node_id: node.id)
          .pluck(:id)

      metadata = node.metadata.is_a?(Hash) ? node.metadata.deep_stringify_keys : {}

      node.update_columns(
        state: DAG::Node::STOPPED,
        finished_at: node.finished_at || now,
        metadata: metadata.merge("reason" => "superseded_pending", "generated_by" => "silent_pending_repair"),
        claim_after_at: nil,
        claimed_at: nil,
        claimed_by: nil,
        started_at: nil,
        heartbeat_at: nil,
        lease_expires_at: nil,
        context_excluded_at: now,
        deleted_at: now,
        compressed_at: now,
        compressed_by_id: node.id,
        updated_at: now,
      )

      if edge_ids.any?
        graph.edges.where(id: edge_ids).update_all(compressed_at: now, updated_at: now)
      end

      cancel_runs_for_node!(node)

      DAG::TurnHeadMaintenance.refresh_for_turn_ids!(
        graph: graph,
        lane_id: node.lane_id,
        turn_ids: [node.turn_id],
      )
    end

    def claim_pending_agent_for_manual_start!(graph:, agent_node:, claimed_by:, now:)
      DAG::Scheduler.claim_pending_node!(graph: graph, node: agent_node, claimed_by: claimed_by, now: now)
    end

    def latest_executing_agent_for_lane(graph:, lane:)
      graph.nodes.active
        .where(
          lane_id: lane.id,
          node_type: Messages::AgentMessage.node_type_key,
          state: [DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL],
        )
        .order(:id)
        .last
    end

    def interrupt_new_turn!(running_agent:, interrupted_output_policy:)
      stable_parent = stable_sequence_parent_for(node: running_agent)
      raise Cybros::Error, "missing_stable_parent" if stable_parent.nil?

      interrupted_nodes = []

      running_agent.causal_descendant_ids.each do |node_id|
        node = root_graph.nodes.active.find_by(id: node_id)
        next if node.nil?
        next unless [DAG::Node::PENDING, DAG::Node::AWAITING_APPROVAL, DAG::Node::RUNNING].include?(node.state)

        stop_node_if_needed!(node, reason: "interrupt_new_turn")
        cancel_runs_for_node!(node)
        interrupted_nodes << node if node.node_type == Messages::AgentMessage.node_type_key
      end

      interrupted_nodes.each do |node|
        apply_interrupted_output_policy!(
          node: node.reload,
          interrupted_output_policy: interrupted_output_policy,
        )
      end

      { stable_parent: stable_parent }
    end

    def stable_sequence_parent_for(node:)
      from_node_id =
        root_graph.edges.active
          .where(to_node_id: node.id, edge_type: DAG::Edge::SEQUENCE)
          .order(:id)
          .pick(:from_node_id)
      return nil if from_node_id.blank?

      root_graph.nodes.active.find_by(id: from_node_id)
    end

    def create_guarded_user_turn!(
      graph:,
      lane:,
      content:,
      model_ref:,
      claim_after_at:,
      sequence_parent:,
      dependency_parent: nil,
      input_policy:
    )
      input_guard = Conversation::InputGuard.classify(conversation: self, content: content, input_policy: input_policy)

      case input_guard.classification
      when :soft
        create_soft_oversize_turn!(
          graph: graph,
          lane: lane,
          content: content,
          model_ref: model_ref,
          claim_after_at: claim_after_at,
          sequence_parent: sequence_parent,
          dependency_parent: dependency_parent,
          input_guard: input_guard,
        )
      when :hard
        create_hard_oversize_turn!(
          graph: graph,
          lane: lane,
          content: content,
          sequence_parent: sequence_parent,
        )
      else
        create_user_turn!(
          graph: graph,
          lane: lane,
          content: content,
          model_ref: model_ref,
          claim_after_at: claim_after_at,
          sequence_parent: sequence_parent,
          dependency_parent: dependency_parent,
        )
      end
    end

    def create_guarded_continuation_for_existing_turn!(
      graph:,
      lane:,
      base_node:,
      user_node:,
      content:,
      model_ref:,
      input_policy:,
      additional_context_text: nil
    )
      mutations = DAG::Mutations.new(graph: graph, turn_id: user_node.turn_id)
      input_guard = Conversation::InputGuard.classify(conversation: self, content: content, input_policy: input_policy)

      case input_guard.classification
      when :soft
        guard_node =
          mutations.create_node(
            node_type: Messages::Task.node_type_key,
            state: DAG::Node::FINISHED,
            lane_id: lane.id,
            body_input: {
              "name" => "compress_input",
              "content" => content,
            },
            body_output: {
              "result" => AgentCore::Resources::Tools::ToolResult.success(
                text: input_guard.compressed_content,
                metadata: { "generated_by" => "compress_input" },
              ).to_h,
            },
            metadata: {
              "generated_by" => "soft_oversize",
              "estimated_tokens" => input_guard.estimated_tokens,
            },
        )
        mutations.create_edge(from_node: base_node, to_node: guard_node, edge_type: DAG::Edge::SEQUENCE)
        user_node.request_exclude_from_context!(at: Time.current)
        agent_node =
          mutations.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            lane_id: lane.id,
            metadata: agent_node_metadata_for(model_ref: model_ref),
          )
        mutations.create_edge(from_node: guard_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

        { guard_node: guard_node, compact_task: nil, agent_node: agent_node }
      when :hard
        product_node =
          mutations.create_node(
            node_type: Messages::ProductMessage.node_type_key,
            state: DAG::Node::FINISHED,
            lane_id: lane.id,
            content: "This input is too large for a single turn. Shorten it, split it into smaller parts, or ask me to compress it first.",
            metadata: {
              "generated_by" => "hard_oversize",
            },
          )
        mutations.create_edge(from_node: base_node, to_node: product_node, edge_type: DAG::Edge::SEQUENCE)

        { agent_node: nil, product_node: product_node }
      else
        agent_node =
          mutations.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            lane_id: lane.id,
            metadata: agent_node_metadata_for(model_ref: model_ref),
          )
        mutations.create_edge(from_node: base_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

        { compact_task: nil, agent_node: agent_node }
      end
    end

    def create_user_turn!(
      graph:,
      lane:,
      content:,
      model_ref:,
      claim_after_at:,
      sequence_parent:,
      dependency_parent: nil
    )
      turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
      mutations = DAG::Mutations.new(graph: graph, turn_id: turn_id)

      user_node =
        mutations.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: content,
          lane_id: lane.id,
          metadata: { "fragments" => [content] },
        )

      if sequence_parent
        mutations.create_edge(from_node: sequence_parent, to_node: user_node, edge_type: DAG::Edge::SEQUENCE)
      end

      agent_node =
        mutations.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: agent_node_metadata_for(model_ref: model_ref),
          claim_after_at: claim_after_at,
        )

      mutations.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

      if dependency_parent && !dependency_parent.terminal?
        mutations.create_edge(
          from_node: dependency_parent,
          to_node: agent_node,
          edge_type: DAG::Edge::DEPENDENCY,
          metadata: { "generated_by" => "queue_policy" }
        )
      end

      { user_node: user_node, compact_task: nil, agent_node: agent_node }
    end

    def create_soft_oversize_turn!(
      graph:,
      lane:,
      content:,
      model_ref:,
      claim_after_at:,
      sequence_parent:,
      dependency_parent:,
      input_guard:
    )
      turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
      mutations = DAG::Mutations.new(graph: graph, turn_id: turn_id)

      user_node =
        mutations.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: content,
          lane_id: lane.id,
          metadata: { "fragments" => [content] },
        )

      compress_task =
        mutations.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          body_input: {
            "name" => "compress_input",
            "content" => content,
          },
          body_output: {
            "result" => AgentCore::Resources::Tools::ToolResult.success(
              text: input_guard.compressed_content,
              metadata: { "generated_by" => "compress_input" },
            ).to_h,
          },
          metadata: {
            "generated_by" => "soft_oversize",
            "estimated_tokens" => input_guard.estimated_tokens,
          },
        )

      if sequence_parent
        mutations.create_edge(from_node: sequence_parent, to_node: user_node, edge_type: DAG::Edge::SEQUENCE)
      end
      mutations.create_edge(from_node: user_node, to_node: compress_task, edge_type: DAG::Edge::SEQUENCE)

      agent_node =
        mutations.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: agent_node_metadata_for(model_ref: model_ref),
          claim_after_at: claim_after_at,
        )

      mutations.create_edge(from_node: compress_task, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

      if dependency_parent && !dependency_parent.terminal?
        mutations.create_edge(
          from_node: dependency_parent,
          to_node: agent_node,
          edge_type: DAG::Edge::DEPENDENCY,
          metadata: { "generated_by" => "queue_policy" }
        )
      end

      user_node.request_exclude_from_context!(at: Time.current)

      { user_node: user_node, guard_node: compress_task, compact_task: nil, agent_node: agent_node }
    end

    def create_hard_oversize_turn!(graph:, lane:, content:, sequence_parent:)
      turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
      mutations = DAG::Mutations.new(graph: graph, turn_id: turn_id)

      user_node =
        mutations.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: content,
          lane_id: lane.id,
          metadata: { "fragments" => [content] },
        )

      product_node =
        mutations.create_node(
          node_type: Messages::ProductMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "This input is too large for a single turn. Shorten it, split it into smaller parts, or ask me to compress it first.",
          metadata: {
            "generated_by" => "hard_oversize",
          },
        )

      if sequence_parent
        mutations.create_edge(from_node: sequence_parent, to_node: user_node, edge_type: DAG::Edge::SEQUENCE)
      end
      mutations.create_edge(from_node: user_node, to_node: product_node, edge_type: DAG::Edge::SEQUENCE)

      { user_node: user_node, agent_node: nil, product_node: product_node }
    end

    def steer_fallback_input_policy_override(input_policy_override:, steer_policy:)
      override =
        if input_policy_override.respond_to?(:to_unsafe_h)
          input_policy_override.to_unsafe_h.deep_stringify_keys
        elsif input_policy_override.is_a?(Hash)
          input_policy_override.deep_stringify_keys
        else
          {}
        end

      override.deep_merge(
        "running_input_policy" => "interrupt_new_turn",
        "interrupted_output_policy" => steer_policy.fetch("interrupted_output_policy"),
      )
    end

    def steer_blocked_by_side_effects?(user_node:, steer_policy:)
      return false if steer_policy.fetch("steer_after_side_effects")

      descendant_ids = user_node.causal_descendant_ids - [user_node.id]
      root_graph.nodes.active.where(id: descendant_ids, node_type: Messages::Task.node_type_key).exists?
    end

    def stop_causal_closure!(root_node:, reason:)
      root_node.causal_descendant_ids.each do |node_id|
        node = root_graph.nodes.active.find_by(id: node_id)
        next if node.nil?
        next unless [DAG::Node::PENDING, DAG::Node::AWAITING_APPROVAL, DAG::Node::RUNNING].include?(node.state)

        stop_node_if_needed!(node, reason: reason)
        cancel_runs_for_node!(node)
      end
    end

    def superseded_block_context_for(user_node:, agent_node:)
      user_text = user_node.body_input["content"].to_s.strip
      assistant_text =
        agent_node.body_output["content"].to_s.presence ||
          agent_node.body_output.dig("message", "content").to_s.presence ||
          agent_node.body_output_preview["content"].to_s.presence

      parts = []
      parts << "Superseded user input:\n#{user_text}" if user_text.present?
      parts << "Interrupted assistant output:\n#{assistant_text}" if assistant_text.present?
      parts.join("\n\n").presence
    end

    def annotate_steered_user_node!(user_node:, content:, steer_policy:)
      metadata = user_node.metadata.is_a?(Hash) ? user_node.metadata.deep_stringify_keys : {}
      metadata["fragments"] = [content]
      metadata["steer_cleanup_policy"] = steer_policy.fetch("steer_cleanup_policy")
      metadata["workspace_cleanup_todo"] = true
      metadata["generated_by"] = "steer_current_turn"
      user_node.update!(metadata: metadata)
    end

    def maybe_create_steer_context_node!(lane:, mutations:, user_node:, preserved_text:, steer_policy:)
      return nil unless steer_policy.fetch("interrupted_output_policy") == "keep_context"

      text = preserved_text.to_s.strip
      return nil if text.blank?

      node =
        mutations.create_node(
          node_type: Messages::SystemMessage.node_type_key,
          state: DAG::Node::FINISHED,
          turn_id: user_node.turn_id,
          lane_id: lane.id,
          content: "<superseded_turn_context>\n#{text}\n</superseded_turn_context>",
          metadata: {
            "generated_by" => "steer_current_turn",
            "steer_cleanup_policy" => steer_policy.fetch("steer_cleanup_policy"),
            "workspace_cleanup_todo" => true,
          },
        )
      mutations.create_edge(from_node: user_node, to_node: node, edge_type: DAG::Edge::SEQUENCE)
      node
    end

    def apply_interrupted_output_policy!(node:, interrupted_output_policy:)
      policy = interrupted_output_policy.to_s

      case policy
      when "discard_context"
        return if node.context_excluded?

        if node.can_exclude_from_context?
          node.exclude_from_context!
        else
          node.request_exclude_from_context!
        end
      when "keep_context"
        return unless node.context_excluded?

        if node.can_include_in_context?
          node.include_in_context!
        else
          node.request_include_in_context!
        end
      end
    end

    def merge_user_message_fragment!(user_node:, content:)
      metadata = user_node.metadata.is_a?(Hash) ? user_node.metadata.deep_stringify_keys : {}
      fragments = Array(metadata["fragments"]).map(&:to_s)
      if fragments.empty?
        initial_content = user_node.body_input["content"].to_s
        fragments << initial_content if initial_content.present?
      end
      fragments << content

      user_node.body_input = user_node.body_input.merge("content" => fragments.join("\n"))
      user_node.metadata = metadata.merge("fragments" => fragments)
      user_node.save!
    end

    def refresh_pending_agent_for_fragment!(agent_node:, model_ref:, claim_after_at:)
      metadata = agent_node.metadata.is_a?(Hash) ? agent_node.metadata.deep_stringify_keys : {}
      metadata.merge!(agent_node_metadata_for(model_ref: model_ref))
      agent_node.update!(metadata: metadata, claim_after_at: claim_after_at)
    end

    def agent_node_metadata_for(model_ref:)
      return {} unless model_ref

      { "llm" => { "model_ref" => model_ref } }
    end
end
