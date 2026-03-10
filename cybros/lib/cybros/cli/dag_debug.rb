module Cybros
  module CLI
    # Runner-only DAG debug implementation.
    #
    # Invoke via one-shot CLI processes like:
    #   `bin/rails runner script/dag_debug.rb ...`
    #
    # Do not call this from long-lived server or job processes.
    class DAGDebug
      class << self
        def inspect_node(node_id)
          node = fetch_node(node_id)

          {
            "node" => node_summary(node),
            "conversation" => conversation_summary(node),
            "retry_chain" => retry_chain(node).map { |entry| node_summary(entry) },
            "incoming_edges" => edge_summaries(node.graph.edges.where(to_node_id: node.id).order(:created_at, :id)),
            "outgoing_edges" => edge_summaries(node.graph.edges.where(from_node_id: node.id).order(:created_at, :id)),
          }
        end

        def context_snapshot(node_id)
          node = fetch_node(node_id)
          graph = node.graph
          context = graph.context_for_full(node.id)
          closure = graph.context_closure_for_full(node.id)
          runtime = AgentCore::DAG.runtime_for(node: node)
          execution_context = AgentCore::DAG::ExecutionContextBuilder.build(node: node, runtime: runtime)
          budget =
            AgentCore::DAG::ContextBudgetManager.new(
              node: node,
              runtime: runtime,
              execution_context: execution_context,
            ).build_prompt(context_nodes: context)

          {
            "node" => node_summary(node),
            "context" => normalize_value(context),
            "closure" => normalize_value(closure),
            "built_prompt" => built_prompt_summary(budget.built_prompt),
          }
        end

        def turn_execution_snapshot(node_id)
          node = fetch_node(node_id)
          conversation = node.graph.attachable
          raise Cybros::Error, "conversation_not_found" unless conversation.is_a?(Conversation)

          execution = conversation.turn_execution_for_node_id(node.id)
          raise Cybros::Error, "turn_execution_not_found" unless execution.is_a?(Hash)

          execution
        end

        def capture_node(node_id, execute: false, retry_first: false, unsafe_direct_execute: false)
          source_node = fetch_node(node_id)
          captured_calls = []
          wire_calls = []
          target_node = source_node

          with_captured_runtime(
            source_node,
            retry_first: retry_first,
            captured_calls: captured_calls,
            wire_calls: wire_calls,
          ) do
            retry_error = nil
            if retry_first
              begin
                target_node = create_retry_target(source_node)
              rescue Cybros::Error => e
                retry_error = e.message
              end
            end

            execution =
              if retry_error
                {
                  "mode" => "retry_inline",
                  "result_state" => source_node.state,
                  "error" => retry_error,
                }
              elsif execute
                if retry_first
                  target_node, execution_summary = execute_inline(target_node, mode: "retry_runner")
                  execution_summary
                elsif safe_inline_execution?(source_node)
                  target_node, execution_summary = execute_inline(source_node)
                  execution_summary
                elsif unsafe_direct_execute
                  {
                    "mode" => "snapshot_only",
                    "error" => "Direct executor mode is not supported because it can leave incomplete DAG state",
                  }
                else
                  {
                    "mode" => "snapshot_only",
                    "error" => "Refusing to execute this node inline. Only claimable pending nodes support inline execute; failed nodes must use --retry-first.",
                  }
                end
              else
                { "mode" => "snapshot_only" }
              end

            snapshot = context_snapshot(target_node.id)

            {
              "source_node" => node_summary(source_node),
              "target_node" => node_summary(target_node),
              "captured_calls" => captured_calls,
              "wire_calls" => wire_calls,
              "context_snapshot" => snapshot,
              "execution" => execution,
            }
          end
        end

        def command_exit_status(command:, result:)
          case command.to_s
          when "capture"
            execution = result.is_a?(Hash) ? result.fetch("execution", {}) : {}
            return 1 if execution.is_a?(Hash) && execution["error"].to_s.present?

            state = execution.is_a?(Hash) ? execution["result_state"].to_s : ""
            return 1 if state.present? && state != DAG::Node::FINISHED

            0
          when "retry"
            result.dig("created_node", "state").to_s == DAG::Node::FINISHED ? 0 : 1
          when "smoke"
            result.dig("agent_node", "state").to_s == DAG::Node::FINISHED ? 0 : 1
          else
            0
          end
        end

        def retry_node_inline(node_id)
          source_node = fetch_node(node_id)
          conversation = source_node.graph.attachable
          raise Cybros::Error, "conversation_not_found" unless conversation.is_a?(Conversation)

          with_inline_jobs do
            created_node_id = conversation.retry_agent_node!(failed_node_id: source_node.id)
            created_node = DAG::Node.find(created_node_id)

            {
              "source_node" => node_summary(source_node.reload),
              "created_node" => node_summary(created_node.reload),
              "conversation_run_id" => ConversationRun.find_by(dag_node_id: created_node.id)&.id,
            }
          end
        end

        def smoke_conversation_inline(conversation_id:, prompt:, model_ref:)
          source_conversation = Conversation.find(conversation_id)

          with_queue_adapter(:test) do
            conversation =
              Conversation.create!(
                user: source_conversation.user,
                title: "Debug smoke #{Time.current.to_i}",
                agent_program: source_conversation.agent_program,
                agent_config_schema_fingerprint: source_conversation.agent_config_schema_fingerprint,
                default_execution_target: source_conversation.default_execution_target,
                metadata:
                  source_conversation.metadata.deep_dup.deep_merge(
                    "statistics" => {
                      "sample_origin" => "debug",
                    },
                    "input_policy" => {
                      "input_coalescing" => { "enabled" => false },
                    },
                  ),
              )

            begin
              result = conversation.append_user_message!(content: prompt, model_ref: model_ref)
              agent, = execute_inline(result.fetch(:agent_node).reload, mode: "smoke_inline")

              {
                "conversation" => {
                  "id" => conversation.id,
                  "title" => conversation.title,
                  "model_ref" => model_ref,
                  "ephemeral" => true,
                  "sample_origin" => conversation.statistics_sample_origin,
                },
                "user_node" => node_summary(result.fetch(:user_node).reload),
                "agent_node" => node_summary(agent),
              }
            ensure
              invocation_scope = AgentRPCInvocation.where(conversation_id: conversation.id)
              session_scope = AgentRPCSession.where(conversation_id: conversation.id)

              invocation_scope.update_all(last_session_id: nil)
              session_scope.update_all(agent_rpc_invocation_id: nil)
              AgentRPCOperationReceipt.where(agent_rpc_invocation_id: invocation_scope.select(:id)).delete_all
              session_scope.delete_all
              invocation_scope.delete_all
              RunDraft.where(conversation_id: conversation.id).delete_all
              ConversationRun.where(conversation_id: conversation.id).delete_all
              conversation.destroy! if conversation.persisted?
            end
          end
        end

        private

          def fetch_node(node_id)
            DAG::Node.find_by(id: node_id.to_s).tap do |node|
              raise ActiveRecord::RecordNotFound, "Node #{node_id} not found" if node.nil?
            end
          end

          def execute_inline(node, mode: "runner")
            claim_node_for_debug!(node)
            DAG::Runner.run_node!(node.id, execute_job_id: "dag_debug")
            reloaded = node.reload
            [reloaded, execution_summary_from_node(reloaded, mode: mode)]
          end

          def create_retry_target(source_node)
            conversation = source_node.graph.attachable
            raise Cybros::Error, "conversation_not_found" unless conversation.is_a?(Conversation)

            with_queue_adapter(:test) do
              created_node_id = conversation.retry_agent_node!(failed_node_id: source_node.id)
              DAG::Node.find(created_node_id).reload
            end
          end

          def safe_inline_execution?(node)
            node.compressed_at.nil? && node.pending? && pending_node_claimable?(node)
          end

          def claim_node_for_debug!(node)
            node.reload
            return node if node.running?

            raise Cybros::Error, "node_not_pending" unless node.pending?
            raise Cybros::Error, "node_compressed" if node.compressed_at.present?
            raise Cybros::Error, "node_not_executable" unless pending_node_claimable?(node)

            now = Time.current
            lease_seconds = node.graph.claim_lease_seconds_for(nil)
            updated =
              DAG::Node.where(id: node.id, state: DAG::Node::PENDING, compressed_at: nil).update_all(
                state: DAG::Node::RUNNING,
                started_at: nil,
                claimed_at: now,
                claimed_by: "dag_debug",
                lease_expires_at: now + lease_seconds,
                heartbeat_at: nil,
                updated_at: now,
              )

            raise Cybros::Error, "node_claim_failed" unless updated == 1

            node.reload
            node.graph.emit_event(
              event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
              subject: node,
              particulars: { "from" => DAG::Node::PENDING, "to" => DAG::Node::RUNNING },
            )
            node
          end

          def pending_node_claimable?(node)
            node.incoming_edges.active.where(edge_type: DAG::Edge::BLOCKING_EDGE_TYPES).includes(:from_node).all? do |edge|
              parent = edge.from_node
              next true if parent.nil? || parent.compressed_at.present?

              if edge.sequence?
                DAG::Node::TERMINAL_STATES.include?(parent.state)
              else
                parent.state == DAG::Node::FINISHED
              end
            end
          end

          def execution_summary_from_node(node, mode:)
            metadata = node.metadata.is_a?(Hash) ? node.metadata : {}

            {
              "mode" => mode,
              "result_state" => node.state,
              "error" => metadata["error"],
              "reason" => metadata["reason"],
              "provider_error_body" => normalize_value(metadata["provider_error_body"]),
            }
          end

          def with_inline_jobs
            with_queue_adapter(:inline) { yield }
          end

          def with_queue_adapter(adapter)
            original_adapter = ActiveJob::Base.queue_adapter
            ActiveJob::Base.queue_adapter = adapter
            yield
          ensure
            ActiveJob::Base.queue_adapter = original_adapter
          end

          def with_captured_runtime(source_node, retry_first:, captured_calls:, wire_calls:)
            original_runtime_resolver = AgentCore::DAG.runtime_resolver
            active_wrappers = []
            AgentCore::DAG.runtime_resolver =
              lambda do |node:|
                runtime = original_runtime_resolver.call(node: node)
                next runtime unless capture_target?(node, source_node: source_node, retry_first: retry_first)

                wrapped_runtime, provider_wrapper = wrap_runtime(runtime, captured_calls: captured_calls, wire_calls: wire_calls)
                active_wrappers << provider_wrapper
                wrapped_runtime
              end

            yield
          ensure
            active_wrappers.each(&:restore!)
            AgentCore::DAG.runtime_resolver = original_runtime_resolver
          end

          def wrap_runtime(runtime, captured_calls:, wire_calls:)
            wrapped_provider = ProviderCapture.new(runtime.provider, captured_calls: captured_calls, wire_calls: wire_calls)
            runtime_attrs = runtime.to_h.merge(provider: wrapped_provider)
            [AgentCore::DAG::Runtime.new(**runtime_attrs), wrapped_provider]
          end

          def capture_target?(node, source_node:, retry_first:)
            return true if node.id == source_node.id
            return false unless retry_first

            node.retry_of_id.to_s == source_node.id.to_s
          end

          def conversation_summary(node)
            conversation = node.graph.attachable
            return nil unless conversation.is_a?(Conversation)

            {
              "id" => conversation.id,
              "title" => conversation.title,
              "user_id" => conversation.user_id,
            }
          end

          def retry_chain(node)
            chain = []
            current = node

            while current
              chain.unshift(current)
              current = current.retry_of
            end

            chain
          end

          def edge_summaries(edges)
            edges.map do |edge|
              {
                "id" => edge.id,
                "from_node_id" => edge.from_node_id,
                "to_node_id" => edge.to_node_id,
                "edge_type" => edge.edge_type,
                "compressed_at" => timestamp(edge.compressed_at),
              }
            end
          end

          def built_prompt_summary(built_prompt)
            {
              "system_prompt" => built_prompt.system_prompt.to_s,
              "messages" => built_prompt.messages.map { |msg| message_summary(msg) },
              "tools" => normalize_value(built_prompt.tools),
              "options" => normalize_value(built_prompt.options),
            }
          end

          def node_summary(node)
            {
              "id" => node.id,
              "node_type" => node.node_type,
              "state" => node.state,
              "turn_id" => node.turn_id,
              "lane_id" => node.lane_id,
              "graph_id" => node.graph_id,
              "retry_of_id" => node.retry_of_id,
              "compressed_at" => timestamp(node.compressed_at),
              "deleted_at" => timestamp(node.deleted_at),
              "context_excluded_at" => timestamp(node.context_excluded_at),
              "metadata" => normalize_value(node.metadata),
              "body_input" => normalize_value(node.body_input),
              "body_output" => normalize_value(node.body_output),
            }
          end

          def message_summary(message)
            {
              "role" => message.role.to_s,
              "content" => normalize_message_content(message.content),
              "tool_call_id" => message.tool_call_id,
              "tool_calls" => Array(message.tool_calls).map { |tool_call| normalize_value(tool_call.to_h) },
            }.compact
          end

        def stream_event_summary(event)
          summary = { "type" => event.respond_to?(:type) ? event.type.to_s : event.class.name }

          case event
          when AgentCore::StreamEvent::TextDelta, AgentCore::StreamEvent::ThinkingDelta
            summary["text"] = event.text.to_s
          when AgentCore::StreamEvent::ToolCallStart
            summary["id"] = event.id
            summary["name"] = event.name
          when AgentCore::StreamEvent::ToolCallDelta
            summary["id"] = event.id
            summary["arguments_delta"] = event.arguments_delta.to_s
          when AgentCore::StreamEvent::ToolCallEnd
            summary["id"] = event.id
            summary["name"] = event.name
            summary["arguments"] = normalize_value(event.arguments)
          when AgentCore::StreamEvent::MessageComplete
            summary["message"] = message_summary(event.message)
          when AgentCore::StreamEvent::Done
            summary["stop_reason"] = event.stop_reason.to_s
            summary["usage"] = normalize_value(event.usage&.to_h)
          when AgentCore::StreamEvent::ErrorEvent
            summary["error_class"] = event.error.class.name
            summary["error_message"] = event.error.message.to_s
            summary["recoverable"] = event.recoverable?
          end

          summary
        end

          def normalize_message_content(content)
            case content
            when Array
              content.map { |item| normalize_message_part(item) }
            else
              normalize_value(content)
            end
          end

          def normalize_message_part(item)
            case item
            when AgentCore::TextContent
              { "type" => "text", "text" => item.text.to_s }
            when AgentCore::ImageContent
              {
                "type" => "image",
                "source_type" => item.source_type.to_s,
                "media_type" => item.media_type.to_s,
                "url" => item.respond_to?(:url) ? item.url.to_s : nil,
              }.compact
            else
              normalize_value(item)
            end
          end

          def normalize_value(value)
            case value
            when Hash
              value.each_with_object({}) do |(key, item), out|
                out[key.to_s] = normalize_value(item)
              end
            when Array
              value.map { |item| normalize_value(item) }
            when String, Numeric, TrueClass, FalseClass, NilClass
              value
            else
              if value.respond_to?(:to_h)
                normalize_value(value.to_h)
              else
                value.to_s
              end
            end
          end

          def timestamp(value)
            value&.iso8601
          rescue StandardError
            value.to_s.presence
          end
      end

      class ProviderCapture
        def initialize(delegate, captured_calls:, wire_calls:)
          @delegate = delegate
          @captured_calls = captured_calls
          @wire_calls = wire_calls
          wrap_simple_inference_client_if_possible!
        end

        def name
          @delegate.name
        end

        def last_call_metadata
          @delegate.respond_to?(:last_call_metadata) ? @delegate.last_call_metadata : {}
        end

        def provider_key
          @delegate.respond_to?(:provider_key) ? @delegate.provider_key : nil
        end

        def model_ref
          @delegate.respond_to?(:model_ref) ? @delegate.model_ref : nil
        end

        def api_model
          @delegate.respond_to?(:api_model) ? @delegate.api_model : nil
        end

        def restore!
          return unless defined?(@simple_provider) && @simple_provider
          return unless defined?(@original_ensure_client) && @original_ensure_client

          original_ensure_client = @original_ensure_client
          @simple_provider.define_singleton_method(:ensure_client!) { original_ensure_client.call }
        rescue StandardError
          nil
        end

        def chat(messages:, model:, tools: nil, stream: false, **options)
          call =
            {
              "provider_class" => @delegate.class.name,
              "model" => model.to_s,
              "stream" => stream == true,
              "messages" => Array(messages).map { |message| DAGDebug.send(:message_summary, message) },
              "tools" => DAGDebug.send(:normalize_value, tools),
              "options" => DAGDebug.send(:normalize_value, options),
            }

          response = @delegate.chat(messages: messages, model: model, tools: tools, stream: stream, **options)
          if stream && response.respond_to?(:each)
            return wrap_stream_response(response, call)
          end

          finalize_call!(call)
          response
        rescue StandardError
          finalize_call!(call)
          raise
        end

        private

          def wrap_stream_response(response, call)
            finalize = method(:finalize_call!)

            Enumerator.new do |y|
              begin
                response.each do |event|
                  (call["stream_events"] ||= []) << DAGDebug.send(:stream_event_summary, event)
                  y << event
                end
              ensure
                finalize.call(call)
              end
            end
          end

          def finalize_call!(call)
            return if call["finalized"] == true

            call["provider_metadata"] = DAGDebug.send(:normalize_value, last_call_metadata)
            call["finalized"] = true
            @captured_calls << call
          end

          def wrap_simple_inference_client_if_possible!
            simple_provider = extract_simple_inference_provider(@delegate)
            return if simple_provider.nil?

            @simple_provider = simple_provider
            @original_ensure_client = simple_provider.method(:ensure_client!)
            original_ensure_client = @original_ensure_client
            captured_wire_calls = @wire_calls

            simple_provider.define_singleton_method(:ensure_client!) do
              client = original_ensure_client.call
              ClientCapture.new(client, captured_wire_calls)
            end
          rescue StandardError
            nil
          end

          def extract_simple_inference_provider(provider)
            return provider if provider.is_a?(AgentCore::Resources::Provider::SimpleInferenceProvider)

            [:@delegate, :@provider].each do |ivar|
              next unless provider.instance_variable_defined?(ivar)

              inner = provider.instance_variable_get(ivar)
              next if inner.nil?

              found = extract_simple_inference_provider(inner)
              return found unless found.nil?
            end

            nil
          rescue StandardError
            nil
          end
      end

      class ClientCapture
        def initialize(delegate, wire_calls)
          @delegate = delegate
          @wire_calls = wire_calls
        end

        def responses(**kwargs)
          entry = capture("responses", kwargs)
          @delegate.responses(**kwargs)
        rescue StandardError => e
          entry["error"] = summarize_error(e) if entry
          raise
        end

        def responses_stream(**kwargs, &block)
          entry = capture("responses_stream", kwargs)
          response =
            @delegate.responses_stream(**kwargs) do |event|
            (entry["events"] ||= []) << DAGDebug.send(:normalize_value, event)
            block.call(event) if block
          end
          entry["response"] = summarize_response(response)
          response
        rescue StandardError => e
          entry["error"] = summarize_error(e) if entry
          raise
        end

        def chat_completions(**kwargs)
          entry = capture("chat_completions", kwargs)
          @delegate.chat_completions(**kwargs)
        rescue StandardError => e
          entry["error"] = summarize_error(e) if entry
          raise
        end

        def chat_completions_stream(**kwargs, &block)
          entry = capture("chat_completions_stream", kwargs)
          response =
            @delegate.chat_completions_stream(**kwargs) do |event|
            (entry["events"] ||= []) << DAGDebug.send(:normalize_value, event)
            block.call(event) if block
          end
          entry["response"] = summarize_response(response)
          response
        rescue StandardError => e
          entry["error"] = summarize_error(e) if entry
          raise
        end

        def method_missing(method_name, *args, **kwargs, &block)
          @delegate.public_send(method_name, *args, **kwargs, &block)
        end

        def respond_to_missing?(method_name, include_private = false)
          @delegate.respond_to?(method_name, include_private) || super
        end

        private

          def capture(method_name, kwargs)
            entry = {
              "method" => method_name,
              "payload" => DAGDebug.send(:normalize_value, kwargs),
            }
            @wire_calls << entry
            entry
          end

          def summarize_response(response)
            return nil if response.nil?

            {
              "class" => response.class.name,
              "status" => response.respond_to?(:status) ? response.status : nil,
              "headers" => DAGDebug.send(:normalize_value, response.respond_to?(:headers) ? response.headers : nil),
              "body" => DAGDebug.send(:normalize_value, response.respond_to?(:body) ? response.body : nil),
            }.compact
          end

          def summarize_error(error)
            summary = {
              "class" => error.class.name,
              "message" => error.message.to_s,
            }

            if error.respond_to?(:status)
              summary["status"] = error.status
            end
            if error.respond_to?(:headers)
              summary["headers"] = DAGDebug.send(:normalize_value, error.headers)
            end
            if error.respond_to?(:body)
              summary["body"] = DAGDebug.send(:normalize_value, error.body)
            end
            if error.respond_to?(:raw_body)
              summary["raw_body"] = error.raw_body.to_s
            end

            summary
          end
      end
    end
  end
end
