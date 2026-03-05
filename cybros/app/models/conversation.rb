class Conversation < ApplicationRecord
  KINDS = %w[root branch thread checkpoint].freeze
  TERMINAL_NODE_STATES = %w[finished errored stopped rejected skipped].freeze
  IN_FLIGHT_NODE_STATES = %w[pending awaiting_approval running].freeze

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

    chat_lane.message_page(
      limit: raw,
      before_message_id: before_message_id.to_s.presence,
      after_message_id: after_message_id.to_s.presence,
      mode: mode,
    )
  rescue DAG::PaginationError => e
    raise Cybros::Error, e.message
  end

  def transcript_page(limit_turns:, before_turn_id: nil, after_turn_id: nil, mode: :preview, include_deleted: false)
    chat_lane.transcript_page(
      limit_turns: limit_turns,
      before_turn_id: before_turn_id,
      after_turn_id: after_turn_id,
      mode: mode,
      include_deleted: include_deleted,
    )
  rescue DAG::PaginationError => e
    raise Cybros::Error, e.message
  end

  def transcript_recent_turns(limit_turns:, mode: :preview, include_deleted: false)
    chat_lane.transcript_recent_turns(
      limit_turns: limit_turns,
      mode: mode,
      include_deleted: include_deleted,
    )
  rescue DAG::PaginationError => e
    raise Cybros::Error, e.message
  end

  def transcript_for(target_node_id, limit_turns: nil, limit: nil, mode: :preview, include_deleted: false)
    root_graph.transcript_for(
      target_node_id,
      limit_turns: limit_turns || DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS,
      limit: limit,
      mode: mode,
      include_deleted: include_deleted,
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

    projection = DAG::TranscriptProjection.new(graph: root_graph)
    projection.project(node_records: nodes, mode: mode)
  end

  def message_for_node_id(node_id:, mode: :full)
    id = node_id.to_s
    node = root_graph.nodes.find_by(id: id)
    raise ActiveRecord::RecordNotFound if node.nil?

    projection = DAG::TranscriptProjection.new(graph: root_graph)
    message = projection.project(node_records: [node], mode: mode).first
    raise ActiveRecord::RecordNotFound unless message.is_a?(Hash)

    message
  end

  def append_user_message_and_project!(content:, mode: :preview)
    result = append_user_message!(content: content)
    raise Cybros::Error, "failed to append message" if result.nil?

    node_ids = [result[:user_node]&.id, result[:agent_node]&.id].compact
    { messages: messages_for_node_ids(node_ids: node_ids, mode: mode), node_ids: node_ids }
  end

  def stop_node!(node_id:, reason: "user_cancelled")
    with_dag_errors_wrapped do
      node = root_graph.nodes.find_by(id: node_id.to_s)
      raise ActiveRecord::RecordNotFound if node.nil?
      raise Cybros::Error, "node_not_running" unless node.running?

      node.stop!(reason: reason.to_s)
      node
    end
  end

  def retry_agent_node!(failed_node_id:)
    with_dag_errors_wrapped do
      graph = root_graph

      failed_node = graph.nodes.find_by(id: failed_node_id.to_s)
      raise ActiveRecord::RecordNotFound if failed_node.nil?

      raise Cybros::Error, "not_an_agent_node" unless failed_node.node_type == Messages::AgentMessage.node_type_key
      raise Cybros::Error, "not_retryable" unless failed_node.errored? || failed_node.stopped?

      retry_depth = 0
      trace_id = failed_node.id.to_s
      while (source_id = graph.nodes.find_by(id: trace_id)&.metadata&.dig("retry_of_node_id"))
        retry_depth += 1
        trace_id = source_id.to_s
      end
      raise Cybros::Error, "retry_limit_reached" if retry_depth >= 5

      existing_retry =
        graph.nodes
          .where(node_type: Messages::AgentMessage.node_type_key, compressed_at: nil)
          .where("metadata ->> 'retry_of_node_id' = ?", failed_node.id.to_s)
          .order(:id)
          .last
      if existing_retry && !existing_retry.terminal?
        raise Cybros::Error, "retry_already_queued"
      end

      from_node_id =
        graph.edges.active
          .where(edge_type: DAG::Edge::SEQUENCE, to_node_id: failed_node.id)
          .order(:id)
          .pick(:from_node_id)
      raise Cybros::Error, "missing_parent" if from_node_id.nil?

      from_node = graph.nodes.find(from_node_id)

      new_agent = nil
      graph.mutate!(turn_id: from_node.turn_id) do |m|
        new_agent =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            lane_id: failed_node.lane_id,
            metadata: { "retry_of_node_id" => failed_node.id.to_s },
          )
        m.create_edge(from_node: from_node, to_node: new_agent, edge_type: DAG::Edge::SEQUENCE)
      end

      ConversationRun.create!(
        conversation: self,
        dag_node_id: new_agent.id,
        state: "queued",
        queued_at: Time.current,
        debug: {},
        error: {},
      )

      graph.kick!

      new_agent.id
    end
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
    preview = output_preview_for_node_id(node_id)
    return nil if preview.fetch("content", "").to_s.blank?

    latest_node_event_id_for(node_id)
  end

  def node_event_page_for(node_id, after_event_id:, limit:, kinds:)
    chat_lane.node_event_page_for(
      node_id.to_s,
      after_event_id: after_event_id.to_s.presence,
      limit: limit,
      kinds: Array(kinds).map(&:to_s),
    )
  end

  def append_user_message!(content:)
    content = content.to_s.strip
    return nil if content.blank?

    with_dag_errors_wrapped do
      graph = root_graph
      lane = chat_lane

      resolution = Cybros::AgentRuntimeResolver.model_resolution_for(conversation: self)
      preferred_models = Array(resolution[:preferred_models]).map(&:to_s).reject(&:blank?)
      matched_preference = !!resolution[:matched_preference]
      chosen_model = resolution[:model].to_s
      provider_name = resolution[:provider_name].to_s

      prev_leaf = head_leaf_for_lane(graph: graph, lane: lane)
      prev_agent_leaf = head_leaf_for_lane(graph: graph, lane: lane, node_type: Messages::AgentMessage.node_type_key)

      turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")

      user_node = nil
      agent_node = nil

      graph.mutate!(turn_id: turn_id) do |m|
        user_node =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: content,
            lane_id: lane.id,
            metadata: {},
          )

        agent_node =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            lane_id: lane.id,
            metadata:
              begin
                if preferred_models.any? && !matched_preference
                  {
                    "llm_warning" => {
                      "code" => "model_preference_unavailable",
                      "preferred_models" => preferred_models,
                      "chosen_model" => chosen_model,
                      "provider_name" => provider_name,
                    },
                  }
                else
                  {}
                end
              end,
          )

        if prev_leaf
          m.create_edge(from_node: prev_leaf, to_node: user_node, edge_type: DAG::Edge::SEQUENCE)
        end
        m.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

        if prev_agent_leaf && !prev_agent_leaf.terminal?
          m.create_edge(
            from_node: prev_agent_leaf,
            to_node: agent_node,
            edge_type: DAG::Edge::DEPENDENCY,
            metadata: { "generated_by" => "queue_policy" }
          )
        end
      end

      agent_leaf = agent_node || graph.leaf_nodes.where(lane_id: lane.id).order(:id).last

      ConversationRun.create!(
        conversation: self,
        dag_node_id: agent_leaf.id,
        state: "queued",
        queued_at: Time.current,
        debug: {},
        error: {},
      )

      graph.kick!

      { user_node: user_node, agent_node: agent_leaf }
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
          root_node =
            m.fork_from!(
              from_node: from_node,
              node_type: Messages::UserMessage.node_type_key,
              state: DAG::Node::FINISHED,
              content: user_content.to_s,
              metadata: {},
            )
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
      raise Cybros::Error, "cannot regenerate deleted node" if target.deleted?

      tail = head_leaf_for_lane(graph: graph, lane: lane, node_type: Messages::AgentMessage.node_type_key)
      if tail.nil? || tail.id.to_s != target.id.to_s
        # Non-tail regenerate: branch first, then regenerate there.
        child = create_child!(from_node_id: target.id, kind: "branch", title: "Branch", user_content: "")
        return { mode: :branched, conversation: child }
      end

      raise Cybros::Error, "cannot regenerate non-terminal agent" unless target.terminal?
      raise Cybros::Error, "agent is not rerunnable" unless target.can_rerun?

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

    def stop_node_if_needed!(node)
      return if node.terminal?

      begin
        node.stop!(reason: "soft_deleted")
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
end
