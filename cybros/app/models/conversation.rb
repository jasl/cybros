class Conversation < ApplicationRecord
  KINDS = %w[root branch thread checkpoint].freeze

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

  def append_user_message!(content:)
    content = content.to_s.strip
    return nil if content.blank?

    graph = root_graph
    lane = chat_lane

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
          metadata: {},
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

  def create_child!(from_node_id:, kind:, title:, user_content:)
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

  def regenerate!(agent_node_id:)
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

  def select_swipe!(agent_node_id:, direction: nil, position: nil)
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

  def exclude_node!(node_id:)
    node = root_graph.nodes.active.find(node_id)
    raise ActiveRecord::RecordNotFound unless node.lane_id.to_s == chat_lane.id.to_s
    if node.can_exclude_from_context?
      node.exclude_from_context!
    else
      node.request_exclude_from_context!
    end
    node
  end

  def include_node!(node_id:)
    node = root_graph.nodes.active.find(node_id)
    raise ActiveRecord::RecordNotFound unless node.lane_id.to_s == chat_lane.id.to_s
    if node.can_include_in_context?
      node.include_in_context!
    else
      node.request_include_in_context!
    end
    node
  end

  def soft_delete_node!(node_id:)
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

  def restore_node!(node_id:)
    node = root_graph.nodes.active.find(node_id)
    raise ActiveRecord::RecordNotFound unless node.lane_id.to_s == chat_lane.id.to_s
    if node.can_restore?
      node.restore!
    else
      node.request_restore!
    end
    node
  end

  def translate!(node_id:, target_lang:)
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

  def clear_translations!
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

  def merge_into_parent!(metadata: {})
    raise Cybros::Error, "merge_into_parent! only valid for non-root conversations" if root?

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

  # Product-level API: returns the best-effort “current chat head” leaf for this
  # conversation’s chat lane, accounting for swipe selection and visibility.
  def chat_head_leaf(node_type: nil)
    head_leaf_for_lane(graph: root_graph, lane: chat_lane, node_type: node_type)
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
