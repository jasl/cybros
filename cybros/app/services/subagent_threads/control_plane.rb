module SubagentThreads
  class ControlPlane
    TRANSCRIPT_LINE_MAX_BYTES = 1_000
    DEFAULT_LIMIT_TURNS = 10
    WAIT_POLL_INTERVAL_MS = 50

    class << self
      def spawn!(parent:, owner_graph:, owner_turn:, owner_node:, request:)
        request = normalize_request(request)
        subagent_id = next_subagent_id
        depth = child_depth_for(parent)

        thread = nil

        Conversation.transaction do
          child =
            Conversation.create!(
              user: parent.user,
              parent_conversation: parent,
              title: thread_title_for(request),
              agent: parent.agent,
              agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
              metadata: build_child_metadata(
                parent: parent,
                owner_graph: owner_graph,
                owner_turn: owner_turn,
                owner_node: owner_node,
                request: request,
                subagent_id: subagent_id,
                depth: depth,
              ),
            )

          seed_child_graph!(child, initial_prompt: request.fetch("prompt"), diagnostic_level: request.fetch("diagnostic_level"))

          thread =
            SubagentThread.create!(
              id: subagent_id,
              owner_conversation: parent,
              owner_graph: owner_graph,
              owner_turn: owner_turn,
              owner_node: owner_node,
              child_conversation: child,
              child_graph: child.dag_graph,
              requested_name: request.fetch("name"),
              title: thread_title_for(request),
              agent_profile: request.fetch("agent_profile"),
              context_turns: request.fetch("context_turns"),
              diagnostic_level: request.fetch("diagnostic_level"),
              status: "active",
              child_status: "pending",
              depth: depth,
              last_snapshot: {},
              final_snapshot: {},
            )
        end

        thread
      end

      def run!(parent:, owner_graph:, owner_turn:, owner_node:, request:, limit_turns: DEFAULT_LIMIT_TURNS)
        thread = spawn!(parent: parent, owner_graph: owner_graph, owner_turn: owner_turn, owner_node: owner_node, request: request)
        thread.child_graph.kick!

        snapshot =
          refresh_snapshot!(
            thread: thread,
            limit_turns: limit_turns,
            operation: "run",
            diagnostic_level: request.fetch("diagnostic_level", nil),
          )

        snapshot.merge(
          "agent_key" => agent_key_for(request.fetch("name")),
          "agent_profile" => request.fetch("agent_profile"),
        )
      end

      def poll!(subagent_id:, parent:, parent_graph:, limit_turns: DEFAULT_LIMIT_TURNS, code_prefix: "cybros.subagent")
        thread = resolve_thread!(subagent_id: subagent_id, parent: parent, parent_graph: parent_graph, code_prefix: code_prefix)
        return missing_snapshot(subagent_id: subagent_id.to_s, operation: "poll", diagnostic_level: nil) if thread.nil?

        refresh_snapshot!(thread: thread, limit_turns: limit_turns, operation: "poll")
      end

      def wait!(subagent_id:, parent:, parent_graph:, limit_turns: DEFAULT_LIMIT_TURNS, timeout_ms:, code_prefix: "cybros.subagent")
        thread = resolve_thread!(subagent_id: subagent_id, parent: parent, parent_graph: parent_graph, code_prefix: code_prefix)
        started_at = monotonic_ms
        timeout_ms = Integer(timeout_ms, exception: false) || 0

        if thread.nil?
          return missing_snapshot(subagent_id: subagent_id.to_s, operation: "wait", diagnostic_level: nil).merge(
            "wait_status" => "missing",
            "timed_out" => false,
            "timeout_ms" => timeout_ms,
            "elapsed_ms" => monotonic_ms - started_at,
          )
        end

        loop do
          snapshot = refresh_snapshot!(thread: thread, limit_turns: limit_turns, operation: "wait")

          if settled?(snapshot)
            return snapshot.merge(
              "wait_status" => "settled",
              "timed_out" => false,
              "timeout_ms" => timeout_ms,
              "elapsed_ms" => monotonic_ms - started_at,
            )
          end

          if monotonic_ms - started_at >= timeout_ms
            return snapshot.merge(
              "wait_status" => "timeout",
              "timed_out" => true,
              "timeout_ms" => timeout_ms,
              "elapsed_ms" => monotonic_ms - started_at,
            )
          end

          thread.child_graph.kick!
          sleep(WAIT_POLL_INTERVAL_MS / 1000.0)
        end
      end

      def send_input!(subagent_id:, parent:, parent_graph:, parent_turn:, input:, limit_turns: DEFAULT_LIMIT_TURNS, code_prefix: "cybros.subagent")
        thread =
          resolve_thread!(
            subagent_id: subagent_id,
            parent: parent,
            parent_graph: parent_graph,
            parent_turn: parent_turn,
            code_prefix: code_prefix,
            enforce_owner_turn: true,
          )
        assert_owned_thread_present!(thread: thread, subagent_id: subagent_id, code_prefix: code_prefix)
        assert_mutable!(thread: thread, code_prefix: code_prefix)

        with_owner_proxy(thread) do
          thread.child_conversation.append_user_message!(content: input.to_s)
        end

        refresh_snapshot!(thread: thread, limit_turns: limit_turns, operation: "send_input")
      end

      def resume!(subagent_id:, parent:, parent_graph:, parent_turn:, limit_turns: DEFAULT_LIMIT_TURNS, code_prefix: "cybros.subagent")
        thread =
          resolve_thread!(
            subagent_id: subagent_id,
            parent: parent,
            parent_graph: parent_graph,
            parent_turn: parent_turn,
            code_prefix: code_prefix,
            enforce_owner_turn: true,
          )
        assert_owned_thread_present!(thread: thread, subagent_id: subagent_id, code_prefix: code_prefix)
        assert_mutable!(thread: thread, code_prefix: code_prefix)

        with_owner_proxy(thread) do
          pending = pending_child_agent!(thread)
          thread.child_conversation.start_pending_agent_node!(node_id: pending.id, claimed_by: "subagent-resume:#{thread.id}")
        end

        refresh_snapshot!(thread: thread, limit_turns: limit_turns, operation: "resume")
      end

      def interrupt!(subagent_id:, parent:, parent_graph:, parent_turn:, limit_turns: DEFAULT_LIMIT_TURNS, code_prefix: "cybros.subagent")
        thread =
          resolve_thread!(
            subagent_id: subagent_id,
            parent: parent,
            parent_graph: parent_graph,
            parent_turn: parent_turn,
            code_prefix: code_prefix,
            enforce_owner_turn: true,
          )
        assert_owned_thread_present!(thread: thread, subagent_id: subagent_id, code_prefix: code_prefix)
        assert_mutable!(thread: thread, code_prefix: code_prefix)

        with_owner_proxy(thread) do
          node = interruptible_child_agent!(thread)
          thread.child_conversation.stop_node!(node_id: node.id, reason: "subagent_interrupt")
        end

        snapshot = refresh_snapshot!(thread: thread, limit_turns: limit_turns, operation: "interrupt")
        record_owner_action_terminal!(thread: thread, reason: "interrupted", snapshot: snapshot)
        snapshot
      end

      def approve!(subagent_id:, parent:, parent_graph:, parent_turn:, node_id:, limit_turns: DEFAULT_LIMIT_TURNS, code_prefix: "cybros.subagent")
        thread =
          resolve_thread!(
            subagent_id: subagent_id,
            parent: parent,
            parent_graph: parent_graph,
            parent_turn: parent_turn,
            code_prefix: code_prefix,
            enforce_owner_turn: true,
          )
        assert_owned_thread_present!(thread: thread, subagent_id: subagent_id, code_prefix: code_prefix)
        assert_mutable!(thread: thread, code_prefix: code_prefix)

        with_owner_proxy(thread) do
          thread.child_conversation.approve_parked_agent_node!(node_id: node_id, approved_by: "subagent-approve:#{thread.id}")
        end

        refresh_snapshot!(thread: thread, limit_turns: limit_turns, operation: "approve")
      end

      def deny!(subagent_id:, parent:, parent_graph:, parent_turn:, node_id:, limit_turns: DEFAULT_LIMIT_TURNS, code_prefix: "cybros.subagent")
        thread =
          resolve_thread!(
            subagent_id: subagent_id,
            parent: parent,
            parent_graph: parent_graph,
            parent_turn: parent_turn,
            code_prefix: code_prefix,
            enforce_owner_turn: true,
          )
        assert_owned_thread_present!(thread: thread, subagent_id: subagent_id, code_prefix: code_prefix)
        assert_mutable!(thread: thread, code_prefix: code_prefix)

        with_owner_proxy(thread) do
          thread.child_conversation.deny_parked_agent_node!(node_id: node_id, denied_by: "subagent-deny:#{thread.id}")
        end

        snapshot = refresh_snapshot!(thread: thread, limit_turns: limit_turns, operation: "deny")
        record_owner_action_terminal!(thread: thread, reason: "approval_denied", snapshot: snapshot)
        snapshot
      end

      def close!(subagent_id:, parent:, parent_graph:, parent_turn:, limit_turns: DEFAULT_LIMIT_TURNS, code_prefix: "cybros.subagent")
        thread =
          resolve_thread!(
            subagent_id: subagent_id,
            parent: parent,
            parent_graph: parent_graph,
            parent_turn: parent_turn,
            code_prefix: code_prefix,
            enforce_owner_turn: true,
          )
        assert_owned_thread_present!(thread: thread, subagent_id: subagent_id, code_prefix: code_prefix)
        assert_mutable!(thread: thread, code_prefix: code_prefix)

        with_owner_proxy(thread) do
          stop_active_child_work!(thread: thread, reason: "subagent_close")
        end

        snapshot = refresh_snapshot!(thread: thread, limit_turns: limit_turns, operation: "close")
        at = Time.current
        thread.update!(
          status: "closed",
          child_status: snapshot.fetch("status", thread.child_status),
          terminal_origin: "owner_action",
          terminal_reason: "closed",
          terminal_at: at,
          closed_at: at,
          final_snapshot: snapshot,
        )
        snapshot
      end

      def refresh_snapshot!(thread:, limit_turns:, operation:, diagnostic_level: nil)
        child = thread.child_conversation
        graph = child&.dag_graph

        snapshot =
          if child.nil? || graph.nil?
            thread.mark_missing!(reason: "child_conversation_missing")
            missing_snapshot(subagent_id: thread.id, operation: operation, diagnostic_level: diagnostic_level)
          elsif graph.nodes.active.exists?
            counts = node_state_counts(graph)
            leaf = leaf_for_main_lane(graph)
            status = status_for_counts(counts)
            status = status_for_terminal_leaf(leaf) if counts.values.all?(&:zero?)

            {
              "ok" => true,
              "subagent_id" => thread.id,
              "operation" => operation,
              "status" => status,
              "counts" => counts,
              "leaf" => leaf,
              "transcript_lines" => transcript_lines_for(graph, limit_turns: limit_turns),
              "result" => structured_result_for_subagent(graph),
              "artifacts" => artifacts_for_subagent(graph),
              "assistant_output_candidate" => assistant_output_candidate_for_subagent(graph, status: status),
              "diagnostic_level" => normalize_diagnostic_level(diagnostic_level || thread.diagnostic_level),
              "error" => subagent_error_payload(graph: graph, leaf: leaf, status: status),
            }.compact
          else
            terminal_snapshot(thread: thread, graph: graph, limit_turns: limit_turns, operation: operation, diagnostic_level: diagnostic_level)
          end

        thread.record_snapshot!(snapshot, final: final_child_status?(snapshot.fetch("status", nil)))
        sync_terminal_metadata!(thread: thread, snapshot: snapshot)
        snapshot
      end

      def resolve_thread!(subagent_id:, parent:, parent_graph:, parent_turn: nil, code_prefix: "cybros.subagent", enforce_owner_turn: false)
        thread = SubagentThread.find_by(id: subagent_id.to_s)
        return nil if thread.nil?

        unless thread&.owner_conversation_id == parent.id && thread&.owner_graph_id == parent_graph.id
          AgentCore::ValidationError.raise!(
            "subagent is not owned by this parent",
            code: "#{code_prefix}.subagent_not_owned",
            details: { subagent_id: subagent_id.to_s },
          )
        end

        if enforce_owner_turn && thread.owner_turn_id.to_s != parent_turn&.id.to_s
          AgentCore::ValidationError.raise!(
            "subagent is not owned by this turn",
            code: "#{code_prefix}.subagent_not_owned_by_turn",
            details: {
              subagent_id: subagent_id.to_s,
              owner_turn_id: thread.owner_turn_id.to_s,
              caller_turn_id: parent_turn&.id.to_s,
            },
          )
        end

        thread
      end

      def build_child_metadata(parent:, owner_graph:, owner_turn:, owner_node:, request:, subagent_id:, depth:)
        {
          "agent" => {
            "key" => agent_key_for(request.fetch("name")),
            "agent_profile" => request.fetch("agent_profile"),
            "context_turns" => request.fetch("context_turns"),
          },
          "subagent" => {
            "subagent_id" => subagent_id,
            "name" => request.fetch("name"),
            "parent_conversation_id" => parent.id.to_s,
            "parent_graph_id" => owner_graph.id.to_s,
            "parent_turn_id" => owner_turn.id.to_s,
            "parent_dag_node_id" => owner_node.id.to_s,
            "spawned_from_node_id" => owner_node.id.to_s,
            "depth" => depth,
          },
          "subagent_thread_id" => subagent_id,
          "owner_conversation_id" => parent.id.to_s,
          "owner_graph_id" => owner_graph.id.to_s,
          "owner_turn_id" => owner_turn.id.to_s,
          "owner_node_id" => owner_node.id.to_s,
          "depth" => depth,
          "statistics" => {
            "sample_origin" => parent.statistics_sample_origin,
          },
        }
      end

      def seed_child_graph!(conversation, initial_prompt:, diagnostic_level:)
        graph = conversation.dag_graph

        graph.mutate! do |m|
          developer =
            m.create_node(
              node_type: Messages::DeveloperMessage.node_type_key,
              state: DAG::Node::FINISHED,
              content: "You are a subagent running in an independent conversation.",
              metadata: { "transcript_visible" => false },
            )

          turn_id = developer.turn_id

          user =
            m.create_node(
              node_type: Messages::UserMessage.node_type_key,
              state: DAG::Node::FINISHED,
              content: initial_prompt,
              metadata: {},
              turn_id: turn_id,
            )

          agent =
            m.create_node(
              node_type: Messages::AgentMessage.node_type_key,
              state: DAG::Node::PENDING,
              metadata: { "turn_execution" => { "diagnostic_level" => normalize_diagnostic_level(diagnostic_level) } },
              turn_id: turn_id,
            )

          m.create_edge(from_node: developer, to_node: user, edge_type: DAG::Edge::SEQUENCE)
          m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
        end
      end

      def next_subagent_id
        ActiveRecord::Base.lease_connection.select_value("select uuidv7()").to_s
      rescue StandardError
        SecureRandom.uuid
      end

      private

        def normalize_request(request)
          request = request.is_a?(Hash) ? request.deep_stringify_keys : {}

          name = request.fetch("name").to_s
          prompt = request.fetch("prompt").to_s
          agent_profile = request.fetch("agent_profile").to_s.presence || Cybros::AgentProfiles::DEFAULT_PROFILE
          context_turns = Integer(request.fetch("context_turns", nil), exception: false) || 50
          title = request.fetch("title", nil).to_s.presence || default_title_for(name)
          diagnostic_level = normalize_diagnostic_level(request.fetch("diagnostic_level", nil))

          {
            "name" => name,
            "prompt" => prompt,
            "agent_profile" => agent_profile,
            "context_turns" => context_turns,
            "title" => title,
            "diagnostic_level" => diagnostic_level,
          }
        end

        def resolve_parent_thread(parent)
          return nil unless parent.respond_to?(:subagent_thread)

          parent.subagent_thread
        end

        def child_depth_for(parent)
          parent_thread = resolve_parent_thread(parent)
          parent_thread ? parent_thread.depth + 1 : 1
        rescue StandardError
          1
        end

        def normalize_name(name)
          name.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
        end

        def agent_key_for(name)
          normalized = normalize_name(name)
          normalized.empty? ? "subagent" : "subagent:#{normalized}"
        end

        def default_title_for(name)
          normalized = name.to_s.strip
          normalized.presence || "Subagent"
        end

        def thread_title_for(request)
          request.fetch("title").to_s
        end

        def normalize_diagnostic_level(value)
          value.to_s == "debug" ? "debug" : "standard"
        end

        def settled?(snapshot)
          !%w[pending running].include?(snapshot.fetch("status").to_s)
        rescue StandardError
          false
        end

        def final_child_status?(value)
          %w[idle failed stopped missing].include?(value.to_s)
        end

        def missing_snapshot(subagent_id:, operation:, diagnostic_level:)
          {
            "ok" => true,
            "subagent_id" => subagent_id,
            "operation" => operation,
            "status" => "missing",
            "counts" => { "pending" => 0, "running" => 0, "awaiting_approval" => 0 },
            "leaf" => nil,
            "transcript_lines" => [],
            "error" => {
              "code" => "subagent_missing",
              "message" => "subagent missing",
            },
            "diagnostic_level" => normalize_diagnostic_level(diagnostic_level),
          }
        end

        def stored_snapshot(thread:, operation:, diagnostic_level:)
          snapshot = thread.snapshot_payload.deep_dup
          snapshot["ok"] = true if snapshot.empty?
          snapshot["subagent_id"] = thread.id
          snapshot["operation"] = operation
          snapshot["status"] ||= thread.child_status
          snapshot["counts"] ||= { "pending" => 0, "running" => 0, "awaiting_approval" => 0 }
          snapshot["leaf"] = nil unless snapshot.key?("leaf")
          snapshot["transcript_lines"] ||= []
          snapshot["diagnostic_level"] = normalize_diagnostic_level(diagnostic_level || snapshot["diagnostic_level"] || thread.diagnostic_level)
          snapshot
        end

        def terminal_snapshot(thread:, graph:, limit_turns:, operation:, diagnostic_level:)
          return stored_snapshot(thread: thread, operation: operation, diagnostic_level: diagnostic_level) unless graph.nodes.active.exists?

          counts = { "pending" => 0, "running" => 0, "awaiting_approval" => 0 }
          leaf = leaf_for_main_lane(graph)
          status = status_for_terminal_leaf(leaf)
          snapshot =
            stored_snapshot(thread: thread, operation: operation, diagnostic_level: diagnostic_level).merge(
              "counts" => counts,
              "leaf" => leaf,
              "transcript_lines" => transcript_lines_for(graph, limit_turns: limit_turns),
              "result" => structured_result_for_subagent(graph),
              "artifacts" => artifacts_for_subagent(graph),
              "assistant_output_candidate" => assistant_output_candidate_for_subagent(graph, status: status),
              "status" => status,
            )

          if %w[failed stopped missing].include?(status)
            snapshot["error"] ||= {
              "code" => "subagent_#{status}",
              "message" => terminal_reason_for_leaf(graph: graph, leaf: leaf),
            }
          end

          snapshot
        end

        def monotonic_ms
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
        rescue StandardError
          (Time.current.to_f * 1000).to_i
        end

        def node_state_counts(graph)
          rows =
            graph.nodes.active
              .where(state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL])
              .group(:state)
              .count

          {
            "pending" => rows.fetch(DAG::Node::PENDING, 0),
            "running" => rows.fetch(DAG::Node::RUNNING, 0),
            "awaiting_approval" => rows.fetch(DAG::Node::AWAITING_APPROVAL, 0),
          }
        rescue StandardError
          { "pending" => 0, "running" => 0, "awaiting_approval" => 0 }
        end

        def status_for_counts(counts)
          return "running" if counts.fetch("running", 0).positive?
          return "awaiting_approval" if counts.fetch("awaiting_approval", 0).positive?
          return "pending" if counts.fetch("pending", 0).positive?

          "idle"
        rescue StandardError
          "idle"
        end

        def status_for_terminal_leaf(leaf)
          case leaf&.fetch("state", nil).to_s
          when DAG::Node::ERRORED, DAG::Node::REJECTED
            "failed"
          when DAG::Node::STOPPED
            "stopped"
          when ""
            "missing"
          else
            "idle"
          end
        rescue StandardError
          "idle"
        end

        def leaf_for_main_lane(graph)
          lane = graph.main_lane
          scope = graph.leaf_nodes.where(lane_id: lane.id)
          visible = scope.where(context_excluded_at: nil, deleted_at: nil)
          leaf = visible.order(:id).last || scope.order(:id).last
          return nil if leaf.nil?

          { "node_id" => leaf.id.to_s, "state" => leaf.state.to_s }
        rescue StandardError
          nil
        end

        def transcript_lines_for(graph, limit_turns:)
          transcript = graph.main_lane.transcript_recent_turns(limit_turns: limit_turns, mode: :preview, include_deleted: false)

          Array(transcript).filter_map do |node|
            payload = node.fetch("payload", {})
            payload = {} unless payload.is_a?(Hash)
            input = payload.fetch("input", {})
            input = {} unless input.is_a?(Hash)
            output_preview = payload.fetch("output_preview", {})
            output_preview = {} unless output_preview.is_a?(Hash)

            text =
              case node.fetch("node_type", "").to_s
              when "user_message"
                "U:#{input.fetch("content", "")}"
              when "agent_message", "character_message"
                "A:#{output_preview.fetch("content", "")}"
              end

            next if text.blank?

            AgentCore::Utils.truncate_utf8_bytes(text, max_bytes: TRANSCRIPT_LINE_MAX_BYTES)
          end
        rescue StandardError
          []
        end

        def structured_result_for_subagent(graph)
          content = latest_assistant_content_for(graph)
          return nil if content.blank?

          { "final_output" => content }
        rescue StandardError
          nil
        end

        def artifacts_for_subagent(graph)
          artifacts = latest_assistant_node_for(graph)&.body_output&.dig("artifacts")
          return artifacts if artifacts.is_a?(Array) || artifacts.is_a?(Hash)

          nil
        rescue StandardError
          nil
        end

        def assistant_output_candidate_for_subagent(graph, status:)
          content = latest_assistant_content_for(graph)
          return nil if content.blank?

          {
            "format" => "text",
            "content" => content,
            "scope" => status.to_s == "idle" ? "full" : "partial",
          }
        rescue StandardError
          nil
        end

        def latest_assistant_content_for(graph)
          node = latest_assistant_node_for(graph)
          return nil if node.nil?

          node.body_output["content"].to_s.presence || node.body_output_preview["content"].to_s.presence
        rescue StandardError
          nil
        end

        def latest_assistant_node_for(graph)
          graph.nodes.active
            .where(lane_id: graph.main_lane.id, node_type: [Messages::AgentMessage.node_type_key, Messages::CharacterMessage.node_type_key])
            .order(:id)
            .last
        rescue StandardError
          nil
        end

        def terminal_reason_for_leaf(graph:, leaf:)
          return "subagent missing" if leaf.nil?

          node = graph.nodes.find_by(id: leaf["node_id"])
          node&.metadata&.fetch("error", nil).to_s.presence ||
            node&.metadata&.fetch("reason", nil).to_s.presence ||
            leaf["state"].to_s
        rescue StandardError
          leaf&.fetch("state", nil).to_s.presence || "subagent terminal"
        end

        def subagent_error_payload(graph:, leaf:, status:)
          return nil unless %w[failed stopped missing].include?(status.to_s)

          {
            "code" => "subagent_#{status}",
            "message" => terminal_reason_for_leaf(graph: graph, leaf: leaf),
          }
        end

        def sync_terminal_metadata!(thread:, snapshot:)
          status = snapshot["status"].to_s
          return unless %w[failed stopped missing].include?(status)
          return unless thread.active?
          return if thread.terminal_origin.to_s == "owner_action" && thread.terminal_at.present?

          reason =
            snapshot.dig("error", "message").to_s.presence ||
              snapshot.dig("error", "code").to_s.presence ||
              status

          thread.update!(
            terminal_origin: "child_runtime",
            terminal_reason: reason,
            terminal_at: Time.current,
            last_error_snapshot: snapshot,
          )
        rescue StandardError
          nil
        end

        def record_owner_action_terminal!(thread:, reason:, snapshot:)
          thread.update!(
            terminal_origin: "owner_action",
            terminal_reason: reason.to_s,
            terminal_at: Time.current,
            last_error_snapshot: %w[failed stopped missing].include?(snapshot["status"].to_s) ? snapshot : thread.last_error_snapshot,
          )
        end

        def assert_mutable!(thread:, code_prefix:)
          return if thread.active?

          AgentCore::ValidationError.raise!(
            "subagent is read-only",
            code: "#{code_prefix}.subagent_read_only",
            details: { subagent_id: thread.id },
          )
        end

        def assert_owned_thread_present!(thread:, subagent_id:, code_prefix:)
          return if thread.present?

          AgentCore::ValidationError.raise!(
            "subagent is not owned by this parent",
            code: "#{code_prefix}.subagent_not_owned",
            details: { subagent_id: subagent_id.to_s },
          )
        end

        def with_owner_proxy(thread)
          Current.set(subagent_owner_proxy_thread_id: thread.id) do
            yield
          end
        end

        def pending_child_agent!(thread)
          node =
            thread.child_graph.nodes.active
              .where(lane_id: thread.child_graph.main_lane.id, node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)
              .order(:id)
              .last
          return node if node.present?

          raise Cybros::Error, "state_changed"
        end

        def interruptible_child_agent!(thread)
          states = [DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL, DAG::Node::PENDING]
          node =
            thread.child_graph.nodes.active
              .where(lane_id: thread.child_graph.main_lane.id, node_type: Messages::AgentMessage.node_type_key, state: states)
              .order(:id)
              .last
          return node if node.present?

          raise Cybros::Error, "node_not_running"
        end

        def stop_active_child_work!(thread:, reason:)
          thread.child_graph.nodes.active
            .where(state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL])
            .find_each do |node|
              node.stop!(reason: reason)
            rescue StandardError
              nil
            end

          thread.child_conversation.turn_internal_tasks.nonterminal.update_all(
            status: "canceled",
            canceled_reason: reason.to_s,
            updated_at: Time.current,
          )
        end
    end
  end
end
