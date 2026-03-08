class Conversation < ApplicationRecord
  KINDS = %w[root branch thread checkpoint].freeze
  TERMINAL_NODE_STATES = %w[finished errored stopped rejected skipped].freeze
  IN_FLIGHT_NODE_STATES = %w[pending awaiting_approval running].freeze
  STATISTICS_SAMPLE_ORIGINS = %w[runtime eval debug replay].freeze
  DEFAULT_STATISTICS_SAMPLE_ORIGIN = "runtime"

  belongs_to :user

  has_one :dag_graph,
          class_name: "DAG::Graph",
          as: :attachable,
          dependent: :destroy,
          autosave: true

  delegate :mutate!, :compress!, :kick!, to: :root_graph, allow_nil: false

  has_one :dag_lane, as: :attachable, class_name: "DAG::Lane", dependent: :nullify

  belongs_to :parent_conversation, class_name: "Conversation", optional: true
  belongs_to :root_conversation, class_name: "Conversation", optional: true
  has_many :child_conversations,
           class_name: "Conversation",
           foreign_key: :parent_conversation_id,
           dependent: :destroy,
           inverse_of: :parent_conversation

  has_many :events, dependent: :destroy

  after_initialize do
    build_dag_graph if new_record? && dag_graph.nil? && root?
  end

  enum :kind, KINDS.index_by(&:itself), default: "root"

  before_validation :assign_root_conversation, on: :create
  before_validation :ensure_statistics_sample_origin, on: :create
  after_create :set_root_conversation_to_self, if: :root?

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

  def statistics_sample_origin
    self.class.normalize_statistics_sample_origin(metadata.is_a?(Hash) ? metadata.dig("statistics", "sample_origin") : nil)
  end

  def self.normalize_statistics_sample_origin(value)
    normalized = value.to_s.strip
    return DEFAULT_STATISTICS_SAMPLE_ORIGIN if normalized.blank?
    return normalized if STATISTICS_SAMPLE_ORIGINS.include?(normalized)

    DEFAULT_STATISTICS_SAMPLE_ORIGIN
  end

  def append_user_message_and_project!(content:, mode: :preview, model_ref: nil, input_policy_override: nil, diagnostic_level: nil)
    result =
      append_user_message!(
        content: content,
        model_ref: model_ref,
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

  def edit_user_message!(node_id:, content:, model_ref: nil, input_policy_override: nil)
    content = content.to_s.strip
    return nil if content.blank?

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
        raise Cybros::Error, edit_action.fetch("reason", "not_editable_now") unless edit_action.fetch("available", false)

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

      if created_new_run
        ConversationRun.create!(
          conversation: self,
          dag_node_id: agent_node.id,
          state: "queued",
          queued_at: Time.current,
          debug: {},
          error: {},
        )

        graph.kick!
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
    with_dag_errors_wrapped do
      node = find_chat_lane_node!(node_id)
      raise Cybros::Error, "node_not_running" unless node_stoppable?(node)

      stopped = node.stop!(reason: reason.to_s)
      raise Cybros::Error, "node_not_running" unless stopped

      cancel_runs_for_node!(node)
      node
    end
  end

  def start_pending_agent_node!(node_id:, claimed_by:)
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

        claim_pending_agent_for_manual_start!(graph: graph, agent_node: started_node, claimed_by: claimed_by, now: now)
        enqueue_execution = true
      end

      DAG::ExecuteNodeJob.perform_later(started_node.id) if enqueue_execution
      started_node
    end
  end

  def retry_agent_node!(failed_node_id:, interrupted_output_policy_override: nil, diagnostic_level: nil)
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
      apply_turn_execution_diagnostic_level!(new_agent, diagnostic_level: diagnostic_level)

      ConversationRun.create!(
        conversation: self,
        dag_node_id: new_agent.id,
        state: "queued",
        queued_at: Time.current,
        debug: turn_execution_debug_payload(diagnostic_level),
        error: {},
      )

      graph.kick!

      new_agent.id
    end
  end

  def steer_current_turn!(content:, model_ref: nil, input_policy_override: nil, interrupted_output_policy_override: nil)
    content = content.to_s.strip
    return nil if content.blank?

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
        ConversationRun.create!(
          conversation: self,
          dag_node_id: agent_node.id,
          state: "queued",
          queued_at: Time.current,
          debug: {},
          error: {},
        )

        graph.kick!
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

  def append_user_message!(content:, model_ref: nil, input_policy_override: nil, repair_pending_tail: true, diagnostic_level: nil)
    content = content.to_s.strip
    return nil if content.blank?

    with_dag_errors_wrapped do
      graph = root_graph
      lane = chat_lane
      diagnostic_level = normalize_turn_execution_diagnostic_level(diagnostic_level)
      model_ref = resolve_model_ref!(requested_model_ref: model_ref)
      policy = resolved_input_policy(app_override: input_policy_override)
      now = Time.current
      claim_after_at = coalescing_claim_after_at(policy: policy, now: now)
      running_input_policy = policy["running_input_policy"].to_s.presence || "queue"

      user_node = nil
      guard_node = nil
      compact_task = nil
      agent_node = nil
      product_node = nil
      created_new_turn = false

      graph.with_graph_lock! do
        running_agent = latest_executing_agent_for_lane(graph: graph, lane: lane)
        sequence_parent = nil
        dependency_parent = nil
        allow_context_compaction = running_agent.blank?

        if running_agent.present? && running_input_policy == "interrupt_new_turn"
          interrupted =
            interrupt_new_turn!(
              running_agent: running_agent,
              interrupted_output_policy: policy.fetch("interrupted_output_policy"),
            )
          sequence_parent = interrupted.fetch(:stable_parent)
          allow_context_compaction = true
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
              allow_context_compaction: allow_context_compaction,
            )
          user_node = created.fetch(:user_node)
          guard_node = created[:guard_node]
          compact_task = created[:compact_task]
          agent_node = created[:agent_node]
          product_node = created[:product_node]
          created_new_turn = agent_node.present?
        end
      end

      if created_new_turn
        apply_turn_execution_diagnostic_level!(agent_node, diagnostic_level: diagnostic_level)

        ConversationRun.create!(
          conversation: self,
          dag_node_id: agent_node.id,
          state: "queued",
          queued_at: Time.current,
          debug: turn_execution_debug_payload(diagnostic_level),
          error: {},
        )

        graph.kick!
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
      from_node = graph.nodes.active.find(from_node_id)
      raise ArgumentError, "wrong lane" unless from_node.lane_id.to_s == chat_lane.id.to_s
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
            kind: kind,
            parent_conversation: self,
            forked_from_node_id: from_node.id,
          )

        graph.mutate! do |m|
          root_node = fork_child_root_node!(mutations: m, from_node: from_node, user_content: user_content)
        end

        root_node.lane.update!(attachable: child)
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

      if target.id.to_s != chat_head_node_id(node_type: Messages::AgentMessage.node_type_key)
        branch_action = action_entry_for(target, "branch")
        raise Cybros::Error, "agent is not rerunnable" unless branch_action.fetch("available", false)

        child = create_child!(from_node_id: target.id, kind: "branch", title: "Branch", user_content: "")
        return { mode: :branched, conversation: child }
      end

      raise Cybros::Error, "agent is not rerunnable" unless regenerate_action.fetch("available", false)

      new_agent = target.rerun!(metadata_patch: { "generated_by" => "regenerate" })

      ConversationRun.create!(
        conversation: self,
        dag_node_id: new_agent.id,
        state: "queued",
        queued_at: Time.current,
        debug: {},
        error: {},
      )

      graph.kick!

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

    versions = node.versions(include_inactive: true).to_a
    raise ArgumentError, "no versions" if versions.empty?

    active_idx = versions.index { |v| v.compressed_at.nil? }
    raise Cybros::Error, "missing active version" if active_idx.nil?

    target_idx =
      if !position.nil?
        raw = position.to_s
        if AgentCore::Utils.uuid_like?(raw)
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
        merge_node =
          m.merge_lanes!(
            target_lane: target_lane,
            target_from_node: target_head,
            source_lanes_and_nodes: [{ lane: source_lane, from_node: source_head }],
            node_type: Messages::AgentMessage.node_type_key,
            metadata: metadata.is_a?(Hash) ? metadata : {},
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
      dag_lane || raise(Cybros::Error, "child conversation is missing dag_lane")
    end
  end

  private

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

    def decorate_transcript_page(page)
      out = page.deep_dup
      out["transcript"] = decorate_messages(out.fetch("transcript", []))
      out
    end

    def decorate_messages(messages)
      messages = Array(messages)
      node_ids = messages.filter_map { |message| message.is_a?(Hash) ? message["node_id"].to_s.presence : nil }
      nodes_by_id = root_graph.nodes.where(id: node_ids).includes(:body).to_a.index_by { |node| node.id.to_s }

      messages.map { |message| decorate_message(message, nodes_by_id: nodes_by_id) }
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

    def decorate_message(message, nodes_by_id: nil)
      return message unless message.is_a?(Hash)

      out = message.deep_dup
      node_id = out["node_id"].to_s
      return out if node_id.blank?

      node = nodes_by_id ? nodes_by_id[node_id] : root_graph.nodes.find_by(id: node_id)
      return out if node.nil?

      out["action_policy"] = action_policy_for(node)
      out["run_state"] = turn_execution_projector.run_state_for_node_id(node.id)
      out
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

    def startable_pending_agent?(node:)
      return false unless node.node_type.to_s == Messages::AgentMessage.node_type_key
      return false unless node.state == DAG::Node::PENDING
      return false if node.compressed_at.present? || node.deleted?
      return false if node.claimed_at.present? || node.started_at.present?
      return false unless node.lane_id.to_s == chat_lane.id.to_s
      return false unless head_leaf_for_lane(graph: root_graph, lane: chat_lane)&.id.to_s == node.id.to_s
      return false if latest_executing_agent_for_lane(graph: root_graph, lane: chat_lane).present?

      true
    end

    def with_dag_errors_wrapped
      yield
    rescue DAG::Error => e
      raise Cybros::Error, e.message
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

      if run.running?
        begin
          node.stop!(reason: "soft_deleted")
        rescue StandardError
          nil
        end
      end

      run.mark_canceled!
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

      DAG::TurnAnchorMaintenance.refresh_for_turn_ids!(
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
      scope = graph.leaf_nodes.where(lane_id: lane.id)
      scope = scope.where(node_type: node_type.to_s) if node_type.present?

      visible_scope = scope.where(context_excluded_at: nil, deleted_at: nil)

      visible = visible_scope.order(:id).last
      return visible if visible

      scope.order(:id).last
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

      DAG::TurnAnchorMaintenance.refresh_for_turn_ids!(
        graph: graph,
        lane_id: node.lane_id,
        turn_ids: [node.turn_id],
      )
    end

    def claim_pending_agent_for_manual_start!(graph:, agent_node:, claimed_by:, now:)
      lease_expires_at = now + graph.claim_lease_seconds_for(nil)
      affected_rows =
        DAG::Node.where(
          id: agent_node.id,
          state: DAG::Node::PENDING,
          compressed_at: nil,
          deleted_at: nil,
          claimed_at: nil,
          started_at: nil,
        ).update_all(
          state: DAG::Node::RUNNING,
          claim_after_at: nil,
          started_at: nil,
          claimed_at: now,
          claimed_by: claimed_by,
          lease_expires_at: lease_expires_at,
          heartbeat_at: nil,
          updated_at: now,
        )

      raise Cybros::Error, "state_changed" unless affected_rows == 1

      agent_node.reload
      graph.emit_event(
        event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
        subject: agent_node,
        particulars: { "from" => DAG::Node::PENDING, "to" => DAG::Node::RUNNING },
      )
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
      input_policy:,
      allow_context_compaction:
    )
      input_guard = Conversation::InputGuard.classify(conversation: self, content: content, input_policy: input_policy)
      context_compaction_plan =
        if allow_context_compaction && input_guard.classification != :hard
          Conversation::ContextCompactionPlan.plan(
            conversation: self,
            content: effective_context_input_for(input_guard: input_guard, content: content),
            input_policy: input_policy,
          )
        end

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
          context_compaction_plan: context_compaction_plan,
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
          context_compaction_plan: context_compaction_plan,
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
      context_input = [effective_context_input_for(input_guard: input_guard, content: content), additional_context_text.presence].compact.join("\n\n")
      context_compaction_plan =
        if input_guard.classification != :hard
          Conversation::ContextCompactionPlan.plan(
            conversation: self,
            content: context_input,
            input_policy: input_policy,
          )
        end

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

        compact_task =
          maybe_create_compact_context_task!(
            graph: graph,
            lane: lane,
            mutations: mutations,
            from_node: guard_node,
            context_compaction_plan: context_compaction_plan,
          )
        agent_node =
          mutations.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            lane_id: lane.id,
            metadata: agent_node_metadata_for(model_ref: model_ref),
          )
        mutations.create_edge(from_node: compact_task || guard_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

        { guard_node: guard_node, compact_task: compact_task, agent_node: agent_node }
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
        compact_task =
          maybe_create_compact_context_task!(
            graph: graph,
            lane: lane,
            mutations: mutations,
            from_node: base_node,
            context_compaction_plan: context_compaction_plan,
          )
        agent_node =
          mutations.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            lane_id: lane.id,
            metadata: agent_node_metadata_for(model_ref: model_ref),
          )
        mutations.create_edge(from_node: compact_task || base_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

        { compact_task: compact_task, agent_node: agent_node }
      end
    end

    def create_user_turn!(
      graph:,
      lane:,
      content:,
      model_ref:,
      claim_after_at:,
      sequence_parent:,
      dependency_parent: nil,
      context_compaction_plan: nil
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

      compact_task =
        maybe_create_compact_context_task!(
          graph: graph,
          lane: lane,
          mutations: mutations,
          from_node: user_node,
          context_compaction_plan: context_compaction_plan,
        )

      agent_node =
        mutations.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: agent_node_metadata_for(model_ref: model_ref),
          claim_after_at: claim_after_at,
        )

      mutations.create_edge(from_node: compact_task || user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

      if dependency_parent && !dependency_parent.terminal?
        mutations.create_edge(
          from_node: dependency_parent,
          to_node: agent_node,
          edge_type: DAG::Edge::DEPENDENCY,
          metadata: { "generated_by" => "queue_policy" }
        )
      end

      { user_node: user_node, compact_task: compact_task, agent_node: agent_node }
    end

    def create_soft_oversize_turn!(
      graph:,
      lane:,
      content:,
      model_ref:,
      claim_after_at:,
      sequence_parent:,
      dependency_parent:,
      input_guard:,
      context_compaction_plan: nil
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

      compact_task =
        maybe_create_compact_context_task!(
          graph: graph,
          lane: lane,
          mutations: mutations,
          from_node: compress_task,
          context_compaction_plan: context_compaction_plan,
        )

      agent_node =
        mutations.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: agent_node_metadata_for(model_ref: model_ref),
          claim_after_at: claim_after_at,
        )

      mutations.create_edge(from_node: compact_task || compress_task, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

      if dependency_parent && !dependency_parent.terminal?
        mutations.create_edge(
          from_node: dependency_parent,
          to_node: agent_node,
          edge_type: DAG::Edge::DEPENDENCY,
          metadata: { "generated_by" => "queue_policy" }
        )
      end

      user_node.request_exclude_from_context!(at: Time.current)

      { user_node: user_node, guard_node: compress_task, compact_task: compact_task, agent_node: agent_node }
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

    def effective_context_input_for(input_guard:, content:)
      return input_guard.compressed_content.to_s if input_guard.classification == :soft

      content
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

    def maybe_create_compact_context_task!(graph:, lane:, mutations:, from_node:, context_compaction_plan:)
      return nil unless context_compaction_plan&.required?

      apply_context_compaction!(
        graph: graph,
        lane: lane,
        turn_ids: context_compaction_plan.compacted_turn_ids,
      )

      compact_task =
        mutations.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          body_input: {
            "name" => "compact_context",
            "compacted_turn_ids" => context_compaction_plan.compacted_turn_ids,
          },
          body_output: {
            "result" => AgentCore::Resources::Tools::ToolResult.success(
              text: context_compaction_plan.summary_text,
              metadata: {
                "generated_by" => "compact_context",
                "compacted_turn_ids" => context_compaction_plan.compacted_turn_ids,
              },
            ).to_h,
          },
          metadata: {
            "generated_by" => "context_overflow",
            "compacted_turn_ids" => context_compaction_plan.compacted_turn_ids,
            "estimated_tokens" => context_compaction_plan.estimated_tokens,
            "effective_prompt_budget_tokens" => context_compaction_plan.effective_prompt_budget_tokens,
          },
        )

      mutations.create_edge(from_node: from_node, to_node: compact_task, edge_type: DAG::Edge::SEQUENCE)
      compact_task
    end

    def apply_context_compaction!(graph:, lane:, turn_ids:)
      ids = Array(turn_ids).map(&:to_s).select(&:present?).uniq
      return if ids.empty?

      nodes = graph.nodes.active.where(lane_id: lane.id, turn_id: ids).to_a
      return if nodes.empty?

      at = Time.current
      lane.send(:apply_compact_context_visibility!, keep_nodes: [], exclude_nodes: nodes, at: at, now: at)
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
