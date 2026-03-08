require "json"

module AgentCore
  module DAG
    module Executors
      class AgentMessageExecutor
        def context_mode = :full

        def execute(node:, context:, stream:)
          runtime = nil
          execution_context = nil
          llm_recovery_metadata = {}

          runtime = AgentCore::DAG.runtime_for(node: node)
          execution_context = ExecutionContextBuilder.build(node: node, runtime: runtime)
          agent_metadata = { agent: execution_context.attributes.fetch(:agent, {}) }

          instrumenter = execution_context.instrumenter

          instrumenter.instrument(
            "agent_core.turn",
            run_id: execution_context.run_id,
            dag: { graph_id: node.graph_id.to_s, node_id: node.id.to_s, turn_id: node.turn_id.to_s },
          ) do
            budget = build_prompt_with_budget(node, context_nodes: context, runtime: runtime, execution_context: execution_context)

            llm =
              call_llm_with_recovery(
                runtime,
                budget.built_prompt,
                stream: stream,
                execution_context: execution_context,
                recovery_metadata_out: llm_recovery_metadata,
              )

            message = llm.fetch(:message)
            stop_reason = llm.fetch(:stop_reason)
            usage = llm.fetch(:usage)
            streamed_output = llm.fetch(:streamed_output)
            used_model = llm.fetch(:used_model)
            llm_metadata = deep_merge_metadata(llm.fetch(:metadata, {}), llm_recovery_metadata)
            directives = llm.fetch(:directives, nil)

            message, tool_call_limit_metadata = apply_tool_call_limit(message, runtime: runtime)

            output_payload =
              build_agent_output_payload(
                message,
                runtime: runtime,
                stop_reason: stop_reason,
                model: used_model,
                directives: directives,
              )

            if message.has_tool_calls? && !can_expand_tool_loop?(node, runtime: runtime)
              content = "Stopped: exceeded max_steps_per_turn."
              override_message = Message.new(role: :assistant, content: content)

              output_payload = build_agent_output_payload(override_message, runtime: runtime, stop_reason: :end_turn, model: used_model)
              output_payload["tool_calls"] = message.tool_calls.map(&:to_h)
              output_payload =
                apply_finalize_output(
                  output_payload: output_payload,
                  message: override_message,
                  runtime: runtime,
                  execution_context: execution_context,
                  context: context,
                  stop_reason: :end_turn,
                  model: used_model,
                  streamed_output: false,
                )

              metadata =
                deep_merge_metadata(
                  budget.metadata,
                  deep_merge_metadata(
                    llm_metadata,
                    deep_merge_metadata(tool_call_limit_metadata, { reason: "max_steps_exceeded" })
                  )
                )
              metadata = deep_merge_metadata(metadata, agent_metadata)

              ::DAG::ExecutionResult.finished(content: content, payload: output_payload, metadata: metadata, usage: usage)
            else
              if message.has_tool_calls?
                tool_loop_metadata =
                  expand_tool_loop!(
                    node,
                    message,
                    visible_tools: budget.built_prompt.tools,
                    runtime: runtime,
                    execution_context: execution_context,
                  )
              else
                tool_loop_metadata = {}
              end

              metadata =
                deep_merge_metadata(
                  budget.metadata,
                  deep_merge_metadata(
                    llm_metadata,
                    deep_merge_metadata(tool_call_limit_metadata, tool_loop_metadata)
                  )
                )
              metadata = deep_merge_metadata(metadata, agent_metadata)
              output_payload =
                apply_finalize_output(
                  output_payload: output_payload,
                  message: message,
                  runtime: runtime,
                  execution_context: execution_context,
                  context: context,
                  stop_reason: stop_reason,
                  model: used_model,
                  streamed_output: streamed_output,
                )

              if streamed_output
                ::DAG::ExecutionResult.finished(payload: output_payload, metadata: metadata, usage: usage, streamed_output: true)
              else
                ::DAG::ExecutionResult.finished(content: output_payload.fetch("content"), payload: output_payload, metadata: metadata, usage: usage)
              end
            end
          end
        rescue AgentCore::ContextWindowExceededError => e
          agent = agent_attributes_from(execution_context: execution_context, runtime: runtime)
          metadata = {
            "context_cost" => {
              "context_window_tokens" => e.context_window,
              "reserved_output_tokens" => e.reserved_output,
              "limit" => e.limit,
              "estimated_tokens" => {
                "total" => e.estimated_tokens,
                "messages" => e.message_tokens,
                "tools" => e.tool_tokens,
              }.compact,
            }.compact,
            "agent" => agent,
          }
          metadata = deep_merge_metadata(metadata, llm_recovery_metadata)
          handle_runtime_error(
            error: e,
            stage: :prepare_turn,
            default_error: "ContextWindowExceededError: #{e.message}",
            default_metadata: metadata,
            runtime: runtime,
            execution_context: execution_context,
            context: context,
          )
        rescue AgentCore::ProviderError => e
          agent = agent_attributes_from(execution_context: execution_context, runtime: runtime)
          metadata = {
            provider: runtime ? runtime_name(runtime) : runtime_name_safe(node),
            status: e.status,
            agent: agent,
          }.compact
          metadata = deep_merge_metadata(metadata, llm_recovery_metadata)
          handle_runtime_error(
            error: e,
            stage: :provider,
            default_error: "ProviderError: #{e.message}",
            default_metadata: metadata,
            runtime: runtime,
            execution_context: execution_context,
            context: context,
          )
        rescue AgentCore::StreamError => e
          agent = agent_attributes_from(execution_context: execution_context, runtime: runtime)
          metadata = {
            provider: runtime ? runtime_name(runtime) : runtime_name_safe(node),
            stream: { "output_committed" => e.output_committed == true },
            agent: agent,
          }.compact
          if e.respond_to?(:body) && e.body.present?
            body_safe = e.body.is_a?(Hash) ? e.body : (e.body.to_s[0..2000] rescue nil)
            metadata["provider_error_body"] = body_safe
          end
          metadata = deep_merge_metadata(metadata, llm_recovery_metadata)
          handle_runtime_error(
            error: e,
            stage: :provider_stream,
            default_error: "#{e.class}: #{e.message}",
            default_metadata: metadata,
            runtime: runtime,
            execution_context: execution_context,
            context: context,
          )
        rescue StandardError => e
          agent = agent_attributes_from(execution_context: execution_context, runtime: runtime)
          metadata = { agent: agent }.compact
          metadata = deep_merge_metadata(metadata, llm_recovery_metadata)
          handle_runtime_error(
            error: e,
            stage: :runtime,
            default_error: "#{e.class}: #{e.message}",
            default_metadata: metadata,
            runtime: runtime,
            execution_context: execution_context,
            context: context,
          )
        end

        private

          def apply_finalize_output(output_payload:, message:, runtime:, execution_context:, context:, stop_reason:, model:, streamed_output:)
            return output_payload if streamed_output
            return output_payload if message.has_tool_calls?

            result =
              runtime.runtime_surface_runner.run(
                surface: runtime.runtime_surface,
                stage: :finalize_output,
                input:
                  AgentCore::RuntimeSurface::Inputs::FinalizeOutput.new(
                    draft_output: AgentCore::Utils.deep_stringify_keys(output_payload),
                    context: Array(context),
                    budget: {
                      runtime_surface: AgentCore::Utils.deep_stringify_keys(execution_context.attributes.fetch(:runtime_surface, {})),
                      context_window_tokens: runtime.context_window_tokens,
                      reserved_output_tokens: runtime.reserved_output_tokens,
                    },
                    helpers: {},
                  ),
                execution_context: execution_context,
              )

            decision = result.decision
            unless decision.is_a?(AgentCore::RuntimeSurface::Decisions::FinalOutput)
              AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
                execution_context: execution_context,
                stage: :finalize_output,
                surface: runtime.runtime_surface,
                outcome: {
                  applied: false,
                  fallback: result.fallback?,
                  final_output: AgentCore::RuntimeSurface::AuditSerializer.output_summary(output_payload),
                },
              )
              return output_payload
            end

            normalized =
              normalize_final_output_payload(
                decision.output,
                fallback: output_payload,
                runtime: runtime,
                stop_reason: stop_reason,
                model: model,
              )

            AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
              execution_context: execution_context,
              stage: :finalize_output,
              surface: runtime.runtime_surface,
              outcome: {
                applied: true,
                fallback: result.fallback?,
                final_output: AgentCore::RuntimeSurface::AuditSerializer.output_summary(normalized),
              },
            )

            normalized
          rescue StandardError
            output_payload
          end

          def handle_runtime_error(error:, stage:, default_error:, default_metadata:, runtime:, execution_context:, context:)
            return ::DAG::ExecutionResult.errored(error: default_error, metadata: default_metadata) unless runtime && execution_context
            return ::DAG::ExecutionResult.errored(error: default_error, metadata: default_metadata) unless handleable_error?(error)

            result =
              runtime.runtime_surface_runner.run(
                surface: runtime.runtime_surface,
                stage: :handle_error,
                input:
                  AgentCore::RuntimeSurface::Inputs::HandleError.new(
                    error: error_view_for(error),
                    stage: stage,
                    context: Array(context),
                    budget: {
                      runtime_surface: AgentCore::Utils.deep_stringify_keys(execution_context.attributes.fetch(:runtime_surface, {})),
                      context_window_tokens: runtime.context_window_tokens,
                      reserved_output_tokens: runtime.reserved_output_tokens,
                    },
                    helpers: {},
                  ),
                execution_context: execution_context,
              )

            decision = result.decision
            action = handled_error_action_for(decision)
            if action == :pass
              AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
                execution_context: execution_context,
                stage: :handle_error,
                surface: runtime.runtime_surface,
                outcome: {
                  action: "pass",
                  result_state: ::DAG::Node::ERRORED,
                },
              )
              return ::DAG::ExecutionResult.errored(error: default_error, metadata: default_metadata)
            end

            payload =
              normalize_final_output_payload(
                decision.output,
                fallback: { "content" => default_error_message_for(action) },
                runtime: runtime,
                stop_reason: :end_turn,
                model: runtime.model,
              )

            AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
              execution_context: execution_context,
              stage: :handle_error,
              surface: runtime.runtime_surface,
                outcome: {
                  action: action,
                  fallback: result.fallback?,
                  result_state: ::DAG::Node::FINISHED,
                  final_output: AgentCore::RuntimeSurface::AuditSerializer.output_summary(payload),
                },
              )

            ::DAG::ExecutionResult.finished(
              content: payload.fetch("content"),
              payload: payload,
              metadata: default_metadata,
            )
          rescue StandardError
            ::DAG::ExecutionResult.errored(error: default_error, metadata: default_metadata)
          end

          def normalize_final_output_payload(value, fallback:, runtime:, stop_reason:, model:)
            fallback = fallback.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(fallback) : {}
            message = normalize_assistant_message(value, fallback: fallback)
            directives = extract_output_directives(value, fallback: fallback)
            build_agent_output_payload(message, runtime: runtime, stop_reason: stop_reason, model: model, directives: directives)
          rescue StandardError
            fallback
          end

          def normalize_assistant_message(value, fallback:)
            message =
              case value
              when AgentCore::Message
                value
              when Hash
                value = AgentCore::Utils.deep_stringify_keys(value)
                if value["message"].is_a?(Hash)
                  Message.from_h(value["message"])
                elsif value.key?("content")
                  Message.new(role: :assistant, content: value["content"].to_s)
                end
              else
                text = value.to_s
                Message.new(role: :assistant, content: text) unless text.empty?
              end

            return message if message.is_a?(Message) && message.role == :assistant

            fallback_content = fallback.fetch("content", fallback.dig("message", "content")).to_s
            Message.new(role: :assistant, content: fallback_content)
          rescue StandardError
            Message.new(role: :assistant, content: fallback.fetch("content", "").to_s)
          end

          def extract_output_directives(value, fallback:)
            hash = value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
            hash.fetch("directives", fallback["directives"])
          rescue StandardError
            fallback["directives"]
          end

          def handleable_error?(error)
            return false if error.is_a?(AgentCore::StreamError) && error.output_committed == true

            true
          rescue StandardError
            true
          end

          def error_view_for(error)
            {
              "class" => error.class.name,
              "message" => AgentCore::Utils.truncate_utf8_bytes(error.message.to_s, max_bytes: 1_000),
              "status" => (error.respond_to?(:status) ? error.status : nil),
              "validation_error" => error.is_a?(AgentCore::ValidationError),
              "recoverable" => (error.respond_to?(:recoverable) ? error.recoverable : nil),
              "code" => (error.respond_to?(:code) ? error.code : nil),
            }.compact
          rescue StandardError
            { "class" => error.class.name }
          end

          def handled_error_action_for(decision)
            return :pass unless decision.is_a?(AgentCore::RuntimeSurface::Decisions::ErrorHandling)

            action = decision.action.to_s.strip.downcase.tr("-", "_").to_sym
            return action if %i[pass user_safe_message ask_human retryable_mask].include?(action)

            :pass
          rescue StandardError
            :pass
          end

          def default_error_message_for(action)
            case action
            when :ask_human
              "I couldn't complete that safely. Human review is required."
            when :retryable_mask
              "Temporary upstream failure. Please retry."
            else
              "Something went wrong. Please try again."
            end
          end

          def publish_review_tool_call_outcome(execution_context:, runtime:, static_decision:, reviewed_tool_call:)
            AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
              execution_context: execution_context,
              stage: :review_tool_call,
              surface: runtime.runtime_surface,
              outcome: {
                static_policy_outcome: static_decision.outcome.to_s,
                final_policy_outcome: reviewed_tool_call.fetch(:decision).outcome.to_s,
                required_confirmation: reviewed_tool_call.fetch(:decision).required == true,
                requested_name: reviewed_tool_call.fetch(:requested_name).to_s,
                resolved_name: reviewed_tool_call.fetch(:resolved_name).to_s,
              },
            )
          rescue StandardError
            nil
          end

          def agent_attributes_from(execution_context:, runtime:)
            agent = execution_context&.attributes&.fetch(:agent, nil)
            agent = runtime&.execution_context_attributes&.fetch(:agent, nil) if agent.nil?
            agent.is_a?(Hash) ? agent : {}
          rescue StandardError
            {}
          end

          def build_prompt_with_budget(node, context_nodes:, runtime:, execution_context:)
            ContextBudgetManager.new(
              node: node,
              runtime: runtime,
              execution_context: execution_context,
            ).build_prompt(context_nodes: context_nodes)
          end

          def call_llm_with_recovery(runtime, built_prompt, stream:, execution_context:, recovery_metadata_out:)
            max_attempts = runtime.agent_call_recovery_attempts.to_i
            attempts = 0
            failures_sample = []

            loop do
              begin
                llm = call_llm(runtime, built_prompt, stream: stream, execution_context: execution_context)
                if attempts.positive?
                  recovery_metadata_out.replace(
                    agent_call_recovery_metadata(
                      attempts: attempts,
                      recovered: 1,
                      failed: 0,
                      exhausted: false,
                      failures_sample: failures_sample,
                    )
                  )
                end
                return llm
              rescue AgentCore::ProviderError, AgentCore::StreamError => e
                retryable = retryable_agent_call_error?(e)
                failures_sample << agent_call_recovery_failure_sample(e) if failures_sample.length < 10

                if retryable && attempts < max_attempts
                  attempts += 1
                  next
                end

                if retryable || attempts.positive?
                  recovery_metadata_out.replace(
                    agent_call_recovery_metadata(
                      attempts: attempts,
                      recovered: 0,
                      failed: 1,
                      exhausted: retryable,
                      failures_sample: failures_sample,
                    )
                  )
                end

                raise
              end
            end
          end

          def call_llm(runtime, built_prompt, stream:, execution_context:)
            directives_config = runtime.directives_config
            if directives_config.is_a?(Hash)
              return call_llm_with_directives(
                runtime,
                built_prompt,
                directives_config: directives_config,
                execution_context: execution_context,
              )
            end

            messages = []

            system_prompt = built_prompt.system_prompt.to_s
            if !system_prompt.strip.empty?
              messages << Message.new(role: :system, content: system_prompt)
            end

            built_prompt.messages.each do |msg|
              unless msg.is_a?(Message)
                ValidationError.raise!(
                  "prompt messages must be AgentCore::Message (got #{msg.class})",
                  code: "agent_core.dag.agent_message_executor.prompt_messages_must_be_agentcore_message_got",
                  details: { message_class: msg.class.name },
                )
              end
              messages << msg
            end

            options = built_prompt.options.is_a?(Hash) ? built_prompt.options.dup : {}
            options = AgentCore::Utils.deep_symbolize_keys(options)

            use_stream = options.fetch(:stream, true) != false
            options.delete(:stream)

            instrumenter = execution_context.instrumenter

            payload = {
              run_id: execution_context.run_id,
              provider: runtime_name(runtime),
              model: runtime.model,
              stream: use_stream,
            }

            instrumenter.instrument("agent_core.llm.call", payload) do
              response =
                runtime.provider.chat(
                  messages: messages,
                  model: runtime.model,
                  tools: built_prompt.tools,
                  stream: use_stream,
                  **options
                )

              if use_stream
                provider_metadata = runtime.provider.respond_to?(:last_call_metadata) ? runtime.provider.last_call_metadata : {}
                stream_chat(enum: response, stream: stream).merge(used_model: runtime.model, metadata: provider_metadata)
              else
                provider_metadata = runtime.provider.respond_to?(:last_call_metadata) ? runtime.provider.last_call_metadata : {}
                sync_chat(response).merge(used_model: runtime.model, metadata: provider_metadata)
              end
            end
          end

          def retryable_agent_call_error?(error)
            case error
            when AgentCore::ProviderError
              retryable_provider_status?(error.status)
            when AgentCore::StreamError
              return false if error.output_committed == true
              return retryable_provider_status?(error.status) if error.error_class == AgentCore::ProviderError.name || !error.status.nil?
              return false if error.validation_error == true

              error.recoverable == true
            else
              false
            end
          rescue StandardError
            false
          end

          def retryable_provider_status?(status)
            code = Integer(status, exception: false)
            return false unless code

            code == 408 || code == 409 || code == 429 || code >= 500
          rescue StandardError
            false
          end

          def agent_call_recovery_metadata(attempts:, recovered:, failed:, exhausted:, failures_sample:)
            {
              "llm_call" => {
                "recovery" => {
                  "attempts" => attempts,
                  "recovered" => recovered,
                  "failed" => failed,
                  "exhausted" => exhausted == true,
                  "failures_sample" => Array(failures_sample).first(10),
                },
              },
            }
          end

          def agent_call_recovery_failure_sample(error)
            sample = { "error_class" => error.class.name.to_s, "message" => error.message.to_s }
            sample["status"] = error.status if error.respond_to?(:status) && !error.status.nil?
            if error.respond_to?(:error_class) && error.error_class.to_s != ""
              sample["source_error_class"] = error.error_class.to_s
            end
            sample["output_committed"] = true if error.respond_to?(:output_committed) && error.output_committed == true
            sample
          rescue StandardError
            { "error_class" => error.class.name.to_s }
          end

          def call_llm_with_directives(runtime, built_prompt, directives_config:, execution_context:)
            if built_prompt.has_tools?
              ValidationError.raise!(
                "directives mode does not support tools",
                code: "agent_core.dag.agent_message_executor.directives_mode_does_not_support_tools",
                details: { tools_count: Array(built_prompt.tools).length },
              )
            end

            system_prompt = built_prompt.system_prompt.to_s

            history = []
            built_prompt.messages.each do |msg|
              unless msg.is_a?(Message)
                ValidationError.raise!(
                  "prompt messages must be AgentCore::Message (got #{msg.class})",
                  code: "agent_core.dag.agent_message_executor.prompt_messages_must_be_agentcore_message_got",
                  details: { message_class: msg.class.name },
                )
              end
              history << msg
            end

            llm_options_defaults = built_prompt.options.is_a?(Hash) ? built_prompt.options.dup : {}
            llm_options_defaults = AgentCore::Utils.deep_symbolize_keys(llm_options_defaults)

            reserved_keys = AgentCore::Directives::Runner::RESERVED_LLM_OPTIONS_KEYS
            reserved_keys.each { |k| llm_options_defaults.delete(k) }

            instrumenter = execution_context.instrumenter

            payload = {
              run_id: execution_context.run_id,
              provider: runtime_name(runtime),
              model: runtime.model,
              stream: false,
              directives: true,
            }

            instrumenter.instrument("agent_core.llm.call", payload) do
              runner =
                AgentCore::Directives::Runner.new(
                  provider: runtime.provider,
                  model: runtime.model,
                  llm_options_defaults: llm_options_defaults,
                  directives_config: directives_config,
                )

              result =
                runner.run(
                  history: history,
                  system: system_prompt,
                  token_counter: runtime.token_counter,
                  context_window: runtime.context_window_tokens,
                  reserved_output_tokens: runtime.reserved_output_tokens,
                )
              result = result.is_a?(Hash) ? result : {}

              assistant_text = result.fetch(:assistant_text, result.fetch("assistant_text", "")).to_s
              directives = Array(result.fetch(:directives, result.fetch("directives", []))).select { |d| d.is_a?(Hash) }

              {
                message: Message.new(role: :assistant, content: assistant_text),
                stop_reason: :end_turn,
                usage: nil,
                streamed_output: false,
                used_model: runtime.model,
                directives: directives,
                metadata: directives_metadata(result),
              }
            end
          end

          def directives_metadata(result)
            h = result.is_a?(Hash) ? result : {}
            ok = h.fetch(:ok, h.fetch("ok", false)) == true

            attempts = Array(h.fetch(:attempts, h.fetch("attempts", [])))
            warnings = Array(h.fetch(:warnings, h.fetch("warnings", [])))

            error_code = nil
            unless ok
              last = attempts.last
              if last.is_a?(Hash)
                error = last[:structured_output_error] || last["structured_output_error"]
                error_code = error[:code] || error["code"] if error.is_a?(Hash)
                error_code ||= "HTTP_ERROR" if last[:http_error] || last["http_error"]
              end
            end

            mode = h.fetch(:mode, h.fetch("mode", nil))
            elapsed_ms = h.fetch(:elapsed_ms, h.fetch("elapsed_ms", nil))

            {
              "directives" => {
                "enabled" => true,
                "ok" => ok,
                "mode" => mode&.to_s,
                "elapsed_ms" => elapsed_ms,
                "attempts" => attempts.length,
                "warnings" => warnings.length,
                "error_code" => error_code&.to_s,
              }.compact,
            }
          rescue StandardError
            { "directives" => { "enabled" => true, "ok" => false } }
          end

          def stream_chat(enum:, stream:)
            final_message = nil
            stop_reason = nil
            usage = nil
            content = +""
            wrote_output_deltas = false

            enum.each do |event|
              case event
              when StreamEvent::TextDelta
                delta = event.text.to_s
                content << delta
                if stream && !delta.empty?
                  stream.output_delta(delta)
                  wrote_output_deltas = true
                end
              when StreamEvent::MessageComplete
                final_message = event.message
              when StreamEvent::Done
                stop_reason = event.stop_reason
                usage = event.usage&.to_h
              when StreamEvent::ErrorEvent
                error = event.error
                raise AgentCore::StreamError.new(
                  error.to_s,
                  output_committed: wrote_output_deltas,
                  status: (error.respond_to?(:status) ? error.status : nil),
                  error_class: error.class.name,
                  validation_error: error.is_a?(AgentCore::ValidationError),
                  recoverable: event.recoverable? == true,
                  body: (error.respond_to?(:body) ? error.body : nil),
                )
              else
                # ignore tool call deltas (already captured in MessageComplete)
              end
            end
          rescue AgentCore::ProviderError => e
            raise AgentCore::StreamError.new(
              e.message,
              output_committed: wrote_output_deltas,
              status: e.status,
              error_class: e.class.name,
              validation_error: e.is_a?(AgentCore::ValidationError),
              recoverable: false,
              body: e.body,
            )
          else
            final_message ||= Message.new(role: :assistant, content: content)
            stop_reason ||= :end_turn

            {
              message: final_message,
              stop_reason: stop_reason,
              usage: usage,
              streamed_output: wrote_output_deltas,
            }
          end

          def sync_chat(resp)
            {
              message: resp.message,
              stop_reason: resp.stop_reason,
              usage: resp.usage&.to_h,
              streamed_output: false,
            }
          end

          def build_agent_output_payload(message, runtime:, stop_reason:, model:, directives: nil)
            tool_calls = message.has_tool_calls? ? AgentCore::Utils.deep_stringify_keys(message.tool_calls.map(&:to_h)) : []

            provider_key = runtime.provider.respond_to?(:provider_key) ? runtime.provider.provider_key.to_s : runtime_name(runtime)
            model_ref = runtime.provider.respond_to?(:model_ref) ? runtime.provider.model_ref.to_s : ""
            api_model = runtime.provider.respond_to?(:api_model) ? runtime.provider.api_model.to_s : model.to_s

            out = {
              "content" => message.text.to_s,
              "message" => AgentCore::Utils.deep_stringify_keys(message.to_h),
              "tool_calls" => tool_calls,
              "stop_reason" => stop_reason.to_s,
              "model" => (model_ref.to_s.strip != "" ? model_ref : model.to_s),
              "provider" => (provider_key.to_s.strip != "" ? provider_key : runtime_name(runtime)),
              "provider_key" => provider_key,
              "api_model" => api_model,
            }
            out["model_ref"] = model_ref if model_ref.to_s.strip != ""
            out["directives"] = AgentCore::Utils.deep_stringify_keys(directives) unless directives.nil?
            out
          end

          def can_expand_tool_loop?(node, runtime:)
            return false unless runtime.max_steps_per_turn

            turn_id = node.turn_id.to_s
            return false if turn_id.empty?

            count =
              node.graph.nodes.active
                .where(turn_id: turn_id, lane_id: node.lane_id)
                .where(node_type: %w[agent_message character_message])
                .count

            count < runtime.max_steps_per_turn
          rescue StandardError
            true
          end

          def expand_tool_loop!(node, message, visible_tools:, runtime:, execution_context:)
            graph = node.graph
            tool_policy = runtime.tool_policy
            diagnostic_level = diagnostic_level_for(node)

            tool_calls = message.tool_calls
            tool_loop_metadata = {}
            tool_name_repairs = {}
            name_resolution_events = []
            invalid_schema_count = 0
            invalid_schema_sample = []
            tool_name_aliases = runtime.tool_name_aliases
            normalize_index = runtime.tool_name_normalize_index

            visible_tool_schemas = index_visible_tool_schemas(visible_tools)
            arguments_repairs = {}

            if runtime.tool_name_repair_attempts.to_i.positive? && Array(visible_tools).any? && Array(tool_calls).any?
              name_repair_result =
                AgentCore::Resources::Tools::ToolNameRepairLoop.call(
                  provider: runtime.provider,
                  requested_model: runtime.model,
                  tool_calls: tool_calls,
                  visible_tools: visible_tools,
                  tools_registry: runtime.tools_registry,
                  max_attempts: runtime.tool_name_repair_attempts,
                  max_output_tokens: runtime.tool_name_repair_max_output_tokens,
                  max_candidates: runtime.tool_name_repair_max_candidates,
                  max_visible_tool_names: runtime.tool_name_repair_max_visible_tool_names,
                  tool_name_aliases: runtime.tool_name_aliases,
                  tool_name_normalize_fallback: runtime.tool_name_normalize_fallback,
                  options: runtime.llm_options,
                  instrumenter: execution_context.instrumenter,
                  run_id: execution_context.run_id,
                )

              tool_name_repairs = name_repair_result.fetch(:tool_name_repairs, {})
              tool_loop_metadata = deep_merge_metadata(tool_loop_metadata, name_repair_result.fetch(:metadata, {}))
            end

            if should_repair_tool_calls?(tool_calls, runtime: runtime)
              original_tool_calls = Array(tool_calls)
              repair_result =
                AgentCore::Resources::Tools::ToolCallRepairLoop.call(
                  provider: runtime.provider,
                  requested_model: runtime.model,
                  tool_calls: tool_calls,
                  visible_tools: visible_tools,
                  max_output_tokens: runtime.tool_call_repair_max_output_tokens,
                  max_attempts: runtime.tool_call_repair_attempts,
                  validate_schema: runtime.tool_call_repair_validate_schema,
                  schema_max_depth: runtime.tool_call_repair_schema_max_depth,
                  max_schema_bytes: runtime.tool_call_repair_max_schema_bytes,
                  max_candidates: runtime.tool_call_repair_max_candidates,
                  tool_name_repairs: tool_name_repairs,
                  tool_name_aliases: runtime.tool_name_aliases,
                  tool_name_normalize_fallback: runtime.tool_name_normalize_fallback,
                  options: runtime.llm_options,
                  instrumenter: execution_context.instrumenter,
                  run_id: execution_context.run_id,
                )

              repaired_tool_calls = repair_result.fetch(:tool_calls, tool_calls)
              arguments_repairs =
                repaired_argument_repairs_by_tool_call_id(
                  original_tool_calls: original_tool_calls,
                  repaired_tool_calls: repaired_tool_calls,
                )
              tool_calls = repaired_tool_calls
              tool_loop_metadata = deep_merge_metadata(tool_loop_metadata, repair_result.fetch(:metadata, {}))
            end

            tasks_created = 0
            awaiting_approval = false
            required_approvals = 0
            denied = 0
            invalid = 0

            graph.mutate!(turn_id: node.turn_id) do |m|
              next_node =
                m.create_node(
                  node_type: node.node_type,
                  state: ::DAG::Node::PENDING,
                  idempotency_key: "agent_core.next_from:#{node.id}",
                  metadata: { "generated_by" => "agent_core.tool_loop" },
                  lane_id: node.lane_id,
                )

              tool_calls.each do |tool_call|
                tool_call_id = tool_call.id.to_s
                requested_name = tool_call.name.to_s
                name_repaired = tool_name_repairs.is_a?(Hash) && tool_name_repairs.key?(tool_call_id)
                arguments_repaired = arguments_repairs[tool_call_id] == true
                effective_name =
                  if name_repaired
                    tool_name_repairs.fetch(tool_call_id).to_s
                  else
                    requested_name
                  end

                resolved =
                  resolve_tool(
                    runtime.tools_registry,
                    effective_name,
                    aliases: tool_name_aliases,
                    enable_normalize_fallback: runtime.tool_name_normalize_fallback,
                    normalize_index: normalize_index,
                  )
                resolved_name = resolved.name
                source = resolved.source
                name_resolution = name_repaired ? :repaired : resolved.resolution_method

                if resolved.exists && !name_repaired && resolved.resolution_method != :exact && name_resolution_events.length < 20
                  name_resolution_events <<
                    {
                      "tool_call_id" => tool_call_id,
                      "requested_name" => requested_name.to_s,
                      "resolved_name" => resolved_name.to_s,
                      "method" => resolved.resolution_method.to_s,
                    }
                end

                arguments = tool_call.arguments || {}
                parse_error = tool_call.arguments_parse_error
                repair = task_repair_flags(name_repaired: name_repaired, arguments_repaired: arguments_repaired)
                arguments_resolution = arguments_repaired ? "repaired" : "original"

                if parse_error
                  invalid += 1
                  tool_error = AgentCore::Resources::Tools::ToolResult.error(text: "Invalid tool arguments (#{parse_error}).")

                  task =
                    m.create_node(
                      node_type: "task",
                      state: ::DAG::Node::FINISHED,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => "invalid_args" },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: name_resolution,
                        arguments: arguments,
                        arguments_resolution: "invalid",
                        repair: repair,
                        source: "invalid_args",
                      ),
                      body_output: { "result" => tool_error.to_h },
                    )

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                  emit_planned_activity!(task: task, diagnostic_level: diagnostic_level)
                  emit_failed_activity!(
                    task: task,
                    phase: planned_phase_for(task),
                    diagnostic_level: diagnostic_level,
                    data: {
                      "reason" => "invalid_args",
                      "error" => tool_error.text.to_s,
                    },
                  )
                  next
                end

                unless resolved.exists
                  denied += 1

                  tool_error =
                    AgentCore::Resources::Tools::ToolResult.error(
                      text: "Tool not found: #{requested_name}"
                    )

                  task =
                    m.create_node(
                      node_type: "task",
                      state: ::DAG::Node::FINISHED,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => "policy" },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: name_resolution,
                        arguments: arguments,
                        arguments_resolution: arguments_resolution,
                        repair: repair,
                        source: "policy",
                      ),
                      body_output: { "result" => tool_error.to_h },
                    )

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                  emit_planned_activity!(task: task, diagnostic_level: diagnostic_level)
                  emit_failed_activity!(
                    task: task,
                    phase: planned_phase_for(task),
                    diagnostic_level: diagnostic_level,
                    data: {
                      "reason" => "tool_not_found",
                      "error" => tool_error.text.to_s,
                    },
                  )
                  next
                end

                decision =
                  begin
                    tool_policy.authorize(name: resolved_name, arguments: arguments, context: execution_context)
                  rescue StandardError => e
                    AgentCore::Resources::Tools::Policy::Decision.deny(reason: "policy_error=#{e.class}")
                  end

                reviewed_tool_call =
                  apply_runtime_surface_review(
                    runtime: runtime,
                    execution_context: execution_context,
                    tool_call_id: tool_call_id,
                    requested_name: requested_name,
                    resolved: resolved,
                    name_resolution: name_resolution,
                    arguments: arguments,
                    static_decision: decision,
                    tool_name_aliases: tool_name_aliases,
                    normalize_index: normalize_index,
                  )

                requested_name = reviewed_tool_call.fetch(:requested_name)
                resolved = reviewed_tool_call.fetch(:resolved)
                resolved_name = reviewed_tool_call.fetch(:resolved_name)
                source = reviewed_tool_call.fetch(:source)
                name_resolution = reviewed_tool_call.fetch(:name_resolution)
                arguments = reviewed_tool_call.fetch(:arguments)
                decision = reviewed_tool_call.fetch(:decision)

                instrument_authorization(execution_context, resolved_name, decision)

                unless resolved.exists
                  denied += 1

                  tool_error =
                    AgentCore::Resources::Tools::ToolResult.error(
                      text: "Tool not found: #{requested_name}"
                    )

                  task =
                    m.create_node(
                      node_type: "task",
                      state: ::DAG::Node::FINISHED,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => "policy" },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: name_resolution,
                        arguments: arguments,
                        arguments_resolution: arguments_resolution,
                        repair: repair,
                        source: "policy",
                      ),
                      body_output: { "result" => tool_error.to_h },
                    )

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                  emit_planned_activity!(task: task, diagnostic_level: diagnostic_level)
                  emit_failed_activity!(
                    task: task,
                    phase: planned_phase_for(task),
                    diagnostic_level: diagnostic_level,
                    data: {
                      "reason" => "tool_not_found",
                      "error" => tool_error.text.to_s,
                    },
                  )
                  next
                end

                case decision.outcome
                when :allow
                  if runtime.tool_call_repair_validate_schema
                    schema = visible_tool_schemas[resolved_name] || schema_from_registry(runtime.tools_registry.find(resolved_name))
                    schema = AgentCore::Resources::Tools::StrictJsonSchema.normalize(schema.is_a?(Hash) ? schema : {})

                    errors =
                      AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(
                        arguments: arguments,
                        schema: schema,
                        max_depth: runtime.tool_call_repair_schema_max_depth,
                      )

                    if errors.any?
                      invalid += 1
                      invalid_schema_count += 1

                      if invalid_schema_sample.length < 10
                        invalid_schema_sample << {
                          "tool_call_id" => tool_call_id,
                          "requested_name" => requested_name.to_s,
                          "resolved_name" => resolved_name.to_s,
                          "errors_summary" => AgentCore::Resources::Tools::JsonSchemaLiteValidator.summarize(errors),
                        }
                      end

                      tool_error =
                        AgentCore::Resources::Tools::ToolResult.error(
                          text: "Invalid tool arguments (schema_invalid): #{AgentCore::Resources::Tools::JsonSchemaLiteValidator.summarize(errors)}"
                        )

                      task =
                        m.create_node(
                          node_type: "task",
                          state: ::DAG::Node::FINISHED,
                          idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                          lane_id: node.lane_id,
                          metadata: { "generated_by" => "agent_core", "source" => "invalid_args" },
                          body_input: task_input_hash(
                            tool_call_id: tool_call_id,
                            requested_name: requested_name,
                            name: resolved_name,
                            name_resolution: name_resolution,
                            arguments: arguments,
                            arguments_resolution: "invalid",
                            repair: repair,
                            source: "invalid_args",
                          ),
                          body_output: { "result" => tool_error.to_h },
                        )

                      m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                      m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                      emit_planned_activity!(task: task, diagnostic_level: diagnostic_level)
                      emit_failed_activity!(
                        task: task,
                        phase: planned_phase_for(task),
                        diagnostic_level: diagnostic_level,
                        data: {
                          "reason" => "invalid_args",
                          "error" => tool_error.text.to_s,
                        },
                      )
                      next
                    end
                  end

                  task =
                    m.create_node(
                      node_type: "task",
                      state: ::DAG::Node::PENDING,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => source },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: name_resolution,
                        arguments: arguments,
                        arguments_resolution: arguments_resolution,
                        repair: repair,
                        source: source,
                      ),
                    )

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                  emit_planned_activity!(task: task, diagnostic_level: diagnostic_level)

                  tasks_created += 1
                when :confirm
                  if runtime.tool_call_repair_validate_schema
                    schema = visible_tool_schemas[resolved_name] || schema_from_registry(runtime.tools_registry.find(resolved_name))
                    schema = AgentCore::Resources::Tools::StrictJsonSchema.normalize(schema.is_a?(Hash) ? schema : {})

                    errors =
                      AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(
                        arguments: arguments,
                        schema: schema,
                        max_depth: runtime.tool_call_repair_schema_max_depth,
                      )

                    if errors.any?
                      invalid += 1
                      invalid_schema_count += 1

                      if invalid_schema_sample.length < 10
                        invalid_schema_sample << {
                          "tool_call_id" => tool_call_id,
                          "requested_name" => requested_name.to_s,
                          "resolved_name" => resolved_name.to_s,
                          "errors_summary" => AgentCore::Resources::Tools::JsonSchemaLiteValidator.summarize(errors),
                        }
                      end

                      tool_error =
                        AgentCore::Resources::Tools::ToolResult.error(
                          text: "Invalid tool arguments (schema_invalid): #{AgentCore::Resources::Tools::JsonSchemaLiteValidator.summarize(errors)}"
                        )

                      task =
                        m.create_node(
                          node_type: "task",
                          state: ::DAG::Node::FINISHED,
                          idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                          lane_id: node.lane_id,
                          metadata: { "generated_by" => "agent_core", "source" => "invalid_args" },
                          body_input: task_input_hash(
                            tool_call_id: tool_call_id,
                            requested_name: requested_name,
                            name: resolved_name,
                            name_resolution: name_resolution,
                            arguments: arguments,
                            arguments_resolution: "invalid",
                            repair: repair,
                            source: "invalid_args",
                          ),
                          body_output: { "result" => tool_error.to_h },
                        )

                      m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                      m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                      emit_planned_activity!(task: task, diagnostic_level: diagnostic_level)
                      emit_failed_activity!(
                        task: task,
                        phase: planned_phase_for(task),
                        diagnostic_level: diagnostic_level,
                        data: {
                          "reason" => "invalid_args",
                          "error" => tool_error.text.to_s,
                        },
                      )
                      next
                    end
                  end

                  awaiting_approval = true

                  approval = {
                    "required" => decision.required == true,
                    "deny_effect" => decision.deny_effect.to_s,
                    "reason" => decision.reason.to_s,
                  }.compact

                  required_approvals += 1 if decision.required == true

                  task =
                    m.create_node(
                      node_type: "task",
                      state: ::DAG::Node::AWAITING_APPROVAL,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => source, "approval" => approval },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: name_resolution,
                        arguments: arguments,
                        arguments_resolution: arguments_resolution,
                        repair: repair,
                        source: source,
                      ),
                    )

                  edge_type = decision.required == true && decision.deny_effect.to_s == "block" ? ::DAG::Edge::DEPENDENCY : ::DAG::Edge::SEQUENCE

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: edge_type)
                  emit_planned_activity!(task: task, diagnostic_level: diagnostic_level)
                  emit_waiting_activity!(task: task, diagnostic_level: diagnostic_level, data: approval)

                  tasks_created += 1
                else
                  denied += 1

                  tool_error =
                    AgentCore::Resources::Tools::ToolResult.error(
                      text: "Tool '#{resolved_name}' denied by policy (reason=#{decision.reason})."
                    )

                  task =
                    m.create_node(
                      node_type: "task",
                      state: ::DAG::Node::FINISHED,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => "policy" },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: name_resolution,
                        arguments: arguments,
                        arguments_resolution: arguments_resolution,
                        repair: repair,
                        source: "policy",
                      ),
                      body_output: { "result" => tool_error.to_h },
                    )

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                  emit_planned_activity!(task: task, diagnostic_level: diagnostic_level)
                  emit_failed_activity!(
                    task: task,
                    phase: "authorization",
                    diagnostic_level: diagnostic_level,
                    data: {
                      "reason" => decision.reason.to_s,
                      "error" => tool_error.text.to_s,
                    },
                  )
                end
              end
            end

            if awaiting_approval
              execution_context.instrumenter.publish(
                "agent_core.pause",
                run_id: execution_context.run_id,
                kind: "awaiting_approval",
              )
            end

            if name_resolution_events.any?
              tool_loop_metadata =
                deep_merge_metadata(
                  tool_loop_metadata,
                  {
                    tool_loop: {
                      tool_name_resolution: name_resolution_events,
                    },
                  }
                )
            end

            if invalid_schema_sample.any?
              tool_loop_metadata =
                deep_merge_metadata(
                  tool_loop_metadata,
                  {
                    tool_loop: {
                      invalid_schema_args: {
                        count: invalid_schema_count,
                        sample: invalid_schema_sample,
                      },
                    },
                  }
                )
            end

            deep_merge_metadata(
              tool_loop_metadata,
              {
                tool_loop: {
                  tasks_created: tasks_created,
                  awaiting_approval: awaiting_approval,
                  required_approvals: required_approvals,
                  denied: denied,
                  invalid: invalid,
                }.compact,
              }
            )
          end

          def apply_tool_call_limit(message, runtime:)
            return [message, {}] unless message&.has_tool_calls?

            limit = runtime.max_tool_calls_per_turn
            return [message, {}] if limit.nil?

            tool_calls = Array(message.tool_calls)
            return [message, {}] if tool_calls.length <= limit

            kept = tool_calls.first(limit)
            dropped = tool_calls.drop(limit)

            dropped_names =
              dropped
                .first(10)
                .map { |tc| tc.respond_to?(:name) ? tc.name.to_s : "" }
                .map(&:strip)
                .reject(&:empty?)
                .map { |name| AgentCore::Utils.truncate_utf8_bytes(name, max_bytes: 200) }

            truncated_message =
              Message.new(
                role: message.role,
                content: message.content,
                tool_calls: kept,
                tool_call_id: message.tool_call_id,
                name: message.name,
                metadata: message.metadata,
              )

            metadata = {
              tool_loop: {
                tool_calls_limit: limit,
                tool_calls_total: tool_calls.length,
                tool_calls_executed: kept.length,
                tool_calls_omitted: dropped.length,
                tool_calls_omitted_names_sample: dropped_names,
              }.compact,
            }

            [truncated_message, metadata]
          rescue StandardError
            [message, {}]
          end

          def index_visible_tool_schemas(tools)
            out = {}

            Array(tools).each do |tool|
              next unless tool.is_a?(Hash)

              h = AgentCore::Utils.symbolize_keys(tool)

              name = h.fetch(:name, nil)
              schema = h.fetch(:parameters, nil)

              if name.nil? || name.to_s.strip.empty?
                type = h.fetch(:type, nil).to_s
                if type == "function" && h.fetch(:function, nil).is_a?(Hash)
                  fn = AgentCore::Utils.symbolize_keys(h.fetch(:function))
                  name = fn.fetch(:name, nil)
                  schema = fn.fetch(:parameters, nil)
                end
              end

              schema ||= h.fetch(:input_schema, nil)

              name = name.to_s.strip
              next if name.empty?

              out[name] ||= schema.is_a?(Hash) ? schema : {}
            rescue StandardError
              next
            end

            out
          end

          def schema_from_registry(tool_info)
            case tool_info
            when AgentCore::Resources::Tools::Tool
              tool_info.parameters
            when Hash
              defn = tool_info.fetch(:definition, nil)
              defn = {} unless defn.is_a?(Hash)

              params = defn.fetch(:input_schema) { defn.fetch(:parameters, {}) }
              params.is_a?(Hash) ? params : {}
            else
              {}
            end
          rescue StandardError
            {}
          end

          ResolvedTool = Data.define(:name, :source, :exists, :resolution_method)

          def resolve_tool(registry, requested_name, aliases:, enable_normalize_fallback:, normalize_index:)
            resolution =
              AgentCore::Resources::Tools::ToolNameResolver.resolve(
                requested_name,
                include_check: ->(name) { registry.include?(name) },
                aliases: aliases,
                enable_normalize_fallback: enable_normalize_fallback,
                normalize_index: normalize_index,
              )

            resolved_name = resolution.resolved_name

            tool_info = registry.find(resolved_name)
            source =
              case tool_info
              when AgentCore::Resources::Tools::Tool
                if resolved_name.start_with?(AgentCore::Resources::Skills::Tools::DEFAULT_TOOL_NAME_PREFIX)
                  "skills"
                else
                  "native"
                end
              when Hash
                "mcp"
              else
                "policy"
              end

            ResolvedTool.new(name: resolved_name, source: source, exists: !tool_info.nil?, resolution_method: resolution.method)
          rescue StandardError
            ResolvedTool.new(name: requested_name.to_s, source: "policy", exists: false, resolution_method: :unknown)
          end

          def apply_runtime_surface_review(
            runtime:,
            execution_context:,
            tool_call_id:,
            requested_name:,
            resolved:,
            name_resolution:,
            arguments:,
            static_decision:,
            tool_name_aliases:,
            normalize_index:
          )
            reviewed =
              {
                requested_name: requested_name,
                resolved: resolved,
                resolved_name: resolved.name,
                source: resolved.source,
                name_resolution: name_resolution,
                arguments: arguments,
                decision: static_decision,
              }

            return reviewed if static_decision.denied?

            outcome =
              runtime.runtime_surface_runner.run(
                surface: runtime.runtime_surface,
                stage: :review_tool_call,
                input:
                  AgentCore::RuntimeSurface::Inputs::ReviewToolCall.new(
                    tool_call: {
                      id: tool_call_id.to_s,
                      name: requested_name.to_s,
                      resolved_name: resolved.name.to_s,
                      arguments: AgentCore::Utils.deep_stringify_keys(arguments),
                      source: resolved.source.to_s,
                      name_resolution: name_resolution.to_s,
                    },
                    context: [],
                    capabilities: {
                      prompt_mode: runtime.prompt_mode,
                    },
                    risk_hints: {
                      static_policy_outcome: static_decision.outcome.to_s,
                      required_confirmation: static_decision.required == true,
                    },
                    helpers: nil,
                  ),
                execution_context: execution_context,
              )

            suggestion = outcome.decision
            return reviewed unless suggestion.is_a?(AgentCore::RuntimeSurface::Decisions::ToolCallSuggestion)

            action = suggestion.action.to_s.strip.downcase.tr("-", "_").to_sym

            reviewed =
              case action
              when :pass, :allow
                reviewed.merge(decision: static_decision)
              when :deny
                reviewed.merge(
                  decision: AgentCore::Resources::Tools::Policy::Decision.deny(reason: suggestion.reason.to_s.presence || "runtime_surface_denied"),
                )
              when :ask_human
                reviewed.merge(
                  decision: merge_surface_confirmation(static_decision: static_decision, reason: suggestion.reason),
                )
              when :rewrite_args
                rewritten = normalize_reviewed_tool_call_rewrite(suggestion.patched_tool_call, fallback_name: requested_name, fallback_arguments: arguments)
                rewritten_name = rewritten.fetch(:name)
                rewritten_arguments = rewritten.fetch(:arguments)
                rewritten_resolved =
                  resolve_tool(
                    runtime.tools_registry,
                    rewritten_name,
                    aliases: tool_name_aliases,
                    enable_normalize_fallback: runtime.tool_name_normalize_fallback,
                    normalize_index: normalize_index,
                  )
                rewritten_name_resolution = :runtime_surface_rewrite
                rewritten_decision =
                  if rewritten_resolved.exists
                    begin
                      runtime.tool_policy.authorize(name: rewritten_resolved.name, arguments: rewritten_arguments, context: execution_context)
                    rescue StandardError => e
                      AgentCore::Resources::Tools::Policy::Decision.deny(reason: "policy_error=#{e.class}")
                    end
                  else
                    AgentCore::Resources::Tools::Policy::Decision.deny(reason: "tool_not_found")
                  end

                final_decision =
                  if static_decision.requires_confirmation? && rewritten_decision.allowed?
                    static_decision
                  else
                    rewritten_decision
                  end

                {
                  requested_name: rewritten_name,
                  resolved: rewritten_resolved,
                  resolved_name: rewritten_resolved.name,
                  source: rewritten_resolved.source,
                  name_resolution: rewritten_name_resolution,
                  arguments: rewritten_arguments,
                  decision: final_decision,
                }
              else
                reviewed
              end

            publish_review_tool_call_outcome(
              execution_context: execution_context,
              runtime: runtime,
              static_decision: static_decision,
              reviewed_tool_call: reviewed,
            )

            reviewed
          rescue StandardError
            reviewed
          end

          def merge_surface_confirmation(static_decision:, reason:)
            return static_decision if static_decision.requires_confirmation?

            AgentCore::Resources::Tools::Policy::Decision.confirm(
              reason: reason.to_s.presence || "runtime_surface_review",
              required: static_decision.required == true,
              deny_effect: static_decision.deny_effect,
            )
          end

          def normalize_reviewed_tool_call_rewrite(value, fallback_name:, fallback_arguments:)
            raw = value.is_a?(Hash) ? AgentCore::Utils.deep_symbolize_keys(value) : {}
            name = raw.fetch(:name, raw.fetch(:resolved_name, fallback_name)).to_s.strip
            name = fallback_name.to_s if name.empty?

            arguments = raw.fetch(:arguments, fallback_arguments)
            arguments = {} unless arguments.is_a?(Hash)

            {
              name: name,
              arguments: AgentCore::Utils.deep_stringify_keys(arguments),
            }
          rescue StandardError
            {
              name: fallback_name.to_s,
              arguments: AgentCore::Utils.deep_stringify_keys(fallback_arguments.is_a?(Hash) ? fallback_arguments : {}),
            }
          end

          def task_input_hash(tool_call_id:, requested_name:, name:, name_resolution:, arguments:, source:, arguments_resolution: "original", repair: nil)
            arguments = arguments.is_a?(Hash) ? arguments : {}
            repair = AgentCore::Utils.deep_stringify_keys(repair) if repair.is_a?(Hash)

            {
              "tool_call_id" => tool_call_id.to_s,
              "requested_name" => requested_name.to_s,
              "name" => name.to_s,
              "name_resolution" => name_resolution.to_s,
              "arguments_resolution" => arguments_resolution.to_s,
              "arguments" => AgentCore::Utils.deep_stringify_keys(arguments),
              "arguments_summary" => summarize_arguments(arguments),
              "source" => source.to_s,
            }.tap do |input|
              input["repair"] = repair if repair.present?
            end
          end

          def repaired_argument_repairs_by_tool_call_id(original_tool_calls:, repaired_tool_calls:)
            original_by_id =
              Array(original_tool_calls).each_with_object({}) do |tool_call, memo|
                memo[tool_call_identity(tool_call)] = tool_call
              end

            Array(repaired_tool_calls).each_with_object({}) do |tool_call, memo|
              original = original_by_id[tool_call_identity(tool_call)]
              next if original.nil?

              original_arguments =
                AgentCore::Utils.deep_stringify_keys(original.respond_to?(:arguments) && original.arguments.is_a?(Hash) ? original.arguments : {})
              repaired_arguments =
                AgentCore::Utils.deep_stringify_keys(tool_call.respond_to?(:arguments) && tool_call.arguments.is_a?(Hash) ? tool_call.arguments : {})
              original_parse_error = original.respond_to?(:arguments_parse_error) ? original.arguments_parse_error.to_s.presence : nil
              repaired_parse_error = tool_call.respond_to?(:arguments_parse_error) ? tool_call.arguments_parse_error.to_s.presence : nil

              memo[tool_call_identity(tool_call)] =
                original_parse_error.present? || original_arguments != repaired_arguments || repaired_parse_error.present?
            end
          end

          def task_repair_flags(name_repaired:, arguments_repaired:)
            flags = {}
            flags["tool_name"] = true if name_repaired
            flags["arguments"] = true if arguments_repaired
            flags.presence
          end

          def tool_call_identity(tool_call)
            tool_call.respond_to?(:id) ? tool_call.id.to_s : ""
          end

          def emit_planned_activity!(task:, diagnostic_level:)
            stream = ::DAG::NodeEventStream.new(node: task)
            activity_kind = activity_kind_for_task(task)

            stream.activity_planned!(
              activity_id: activity_id_for(task),
              activity_kind: activity_kind,
              phase: planned_phase_for(task),
              source_node_id: task.id,
              diagnostic_level: diagnostic_level,
            )
          end

          def emit_waiting_activity!(task:, diagnostic_level:, data:)
            stream = ::DAG::NodeEventStream.new(node: task)

            stream.activity_waiting!(
              activity_id: activity_id_for(task),
              activity_kind: activity_kind_for_task(task),
              phase: "authorization",
              source_node_id: task.id,
              diagnostic_level: diagnostic_level,
              data: data,
            )
          end

          def emit_failed_activity!(task:, phase:, diagnostic_level:, data:)
            stream = ::DAG::NodeEventStream.new(node: task)

            stream.activity_failed!(
              activity_id: activity_id_for(task),
              activity_kind: activity_kind_for_task(task),
              phase: phase,
              source_node_id: task.id,
              diagnostic_level: diagnostic_level,
              data: data,
            )
          end

          def activity_id_for(task)
            "task:#{task.id}"
          end

          def activity_kind_for_task(task)
            name = task.body_input.fetch("name", task.body_input.fetch("requested_name", "")).to_s
            %w[compress_input compact_context].include?(name) ? "preflight_task" : "tool_call"
          rescue StandardError
            "tool_call"
          end

          def planned_phase_for(task)
            activity_kind_for_task(task) == "preflight_task" ? "preflight" : "planning"
          end

          def summarize_arguments(arguments)
            json = JSON.generate(arguments)
            AgentCore::Utils.truncate_utf8_bytes(json, max_bytes: 4_000)
          rescue StandardError
            ""
          end

          def instrument_authorization(execution_context, tool_name, decision)
            execution_context.instrumenter.publish(
              "agent_core.tool.authorize",
              run_id: execution_context.run_id,
              tool: tool_name.to_s,
              outcome: decision.outcome.to_s,
              required: decision.required == true,
            )
          rescue StandardError
            nil
          end

          def diagnostic_level_for(node)
            agent =
              node.graph.nodes.active
                .where(lane_id: node.lane_id, turn_id: node.turn_id, node_type: %w[agent_message character_message])
                .order(:id)
                .last

            level =
              if agent&.metadata.is_a?(Hash)
                agent.metadata.dig("turn_execution", "diagnostic_level")
              end

            level.to_s == "debug" ? "debug" : "standard"
          rescue StandardError
            "standard"
          end

          def deep_merge_metadata(a, b)
            a = a.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(a) : {}
            b = b.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(b) : {}
            a.deep_merge(b)
          rescue StandardError
            a.merge(b)
          end

          def runtime_name(runtime)
            if runtime.provider.respond_to?(:name)
              runtime.provider.name.to_s
            else
              runtime.provider.class.name
            end
          rescue StandardError
            "unknown"
          end

          def runtime_name_safe(node)
            runtime = AgentCore::DAG.runtime_for(node: node)
            runtime_name(runtime)
          rescue StandardError
            nil
          end

          def should_repair_tool_calls?(tool_calls, runtime:)
            attempts = runtime.tool_call_repair_attempts.to_i
            return false if attempts <= 0

            Array(tool_calls).any?
          rescue StandardError
            false
          end
      end
    end
  end
end
