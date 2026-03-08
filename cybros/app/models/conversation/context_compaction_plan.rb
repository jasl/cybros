class Conversation::ContextCompactionPlan
  Result =
    Data.define(
      :required,
      :estimated_tokens,
      :effective_prompt_budget_tokens,
      :compacted_turn_ids,
      :summary_text,
    ) do
      def required?
        required
      end
    end

  def self.plan(conversation:, content:, input_policy:, runtime_surface_resolution: nil)
    new(
      conversation: conversation,
      content: content,
      input_policy: input_policy,
      runtime_surface_resolution: runtime_surface_resolution,
    ).plan
  end

  def initialize(conversation:, content:, input_policy:, runtime_surface_resolution: nil)
    @conversation = conversation
    @content = content.to_s
    @input_policy = input_policy.is_a?(Hash) ? input_policy : {}
    @runtime_surface_resolution = runtime_surface_resolution
  end

  def plan
    budget = effective_prompt_budget_tokens
    estimated = estimated_tokens_for(context_nodes: transcript_nodes + [synthetic_user_node])

    return build_result(required: false, estimated: estimated, budget: budget) unless strategy == "compact_context"
    return build_result(required: false, estimated: estimated, budget: budget) if estimated <= budget

    compacted_turn_ids = compacted_turn_ids_for(budget: budget)
    return build_result(required: false, estimated: estimated, budget: budget) if compacted_turn_ids.empty?

    compacted_nodes = transcript_nodes.select { |node| compacted_turn_ids.include?(node.fetch("turn_id").to_s) }
    summary_text = summary_text_for(compacted_nodes: compacted_nodes, budget: budget)
    compacted_turn_ids, summary_text =
      apply_runtime_surface_compaction(
        compacted_turn_ids: compacted_turn_ids,
        summary_text: summary_text,
        estimated: estimated,
        budget: budget,
      )

    build_result(
      required: true,
      estimated: estimated,
      budget: budget,
      compacted_turn_ids: compacted_turn_ids,
      summary_text: summary_text,
    )
  end

  private

    def build_result(required:, estimated:, budget:, compacted_turn_ids: [], summary_text: nil)
      Result.new(
        required: required,
        estimated_tokens: estimated,
        effective_prompt_budget_tokens: budget,
        compacted_turn_ids: compacted_turn_ids,
        summary_text: summary_text,
      )
    end

    def strategy
      @input_policy.dig("oversize", "multi_message", "strategy").to_s.presence || "compact_context"
    end

    def transcript_nodes
      @transcript_nodes ||= @conversation.chat_lane.transcript_recent_turns(limit_turns: Cybros::AgentRuntimeResolver::MAX_CONTEXT_TURNS, mode: :full)
    end

    def compacted_turn_ids_for(budget:)
      turn_ids = transcript_nodes.filter_map { |node| node.fetch("turn_id").to_s.presence }.uniq
      kept_turn_ids = turn_ids.dup
      compacted_turn_ids = []

      while kept_turn_ids.any?
        estimate =
          estimated_tokens_for(
            context_nodes:
              transcript_nodes.select { |node| kept_turn_ids.include?(node.fetch("turn_id").to_s) } + [synthetic_user_node],
          )
        break if estimate <= budget

        compacted_turn_ids << kept_turn_ids.shift
      end

      compacted_turn_ids
    end

    def summary_text_for(compacted_nodes:, budget:)
      lines = compacted_nodes.filter_map { |node| compacted_line_for(node) }
      text = if lines.any?
        "[Compacted prior context]\n#{lines.join("\n")}"
      else
        "[Compacted prior context]\nOlder conversation context was compacted before this turn."
      end

      truncate_to_token_limit(text, token_limit: [[budget / 4, 128].max, budget].min)
    end

    def apply_runtime_surface_compaction(compacted_turn_ids:, summary_text:, estimated:, budget:)
      resolution = runtime_surface_resolution
      return [compacted_turn_ids, summary_text] unless resolution.is_a?(Hash)

      runner = resolution.fetch(:runtime_surface_runner, nil)
      surface = resolution.fetch(:runtime_surface, nil)
      return [compacted_turn_ids, summary_text] if runner.nil? || surface.nil?

      execution_context =
        AgentCore::ExecutionContext.new(
          attributes: {
            conversation_id: @conversation.id,
          },
        )

      outcome =
        runner.run(
          surface: surface,
          stage: :compact_context,
          input: compact_context_input(estimated: estimated, budget: budget),
          execution_context: execution_context,
        )

      decision = outcome.decision
      unless decision.is_a?(AgentCore::RuntimeSurface::Decisions::ContextCompaction)
        AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
          execution_context: execution_context,
          stage: :compact_context,
          surface: surface,
          outcome: {
            kept_count: 0,
            summary_changed: false,
            fallback: outcome.fallback?,
          },
        )
        return [compacted_turn_ids, summary_text]
      end

      adjusted_turn_ids, keep_applied =
        apply_kept_items(
          decision: decision,
          compacted_turn_ids: compacted_turn_ids,
          budget: budget,
        )
      adjusted_summary_text =
        if keep_applied == false
          summary_text
        else
          summary_text_from_decision(decision) || summary_text
        end

      AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
        execution_context: execution_context,
        stage: :compact_context,
        surface: surface,
        outcome: {
          kept_count: Array(decision.kept_items).length,
          keep_applied: keep_applied,
          summary_changed: adjusted_summary_text != summary_text,
          fallback: outcome.fallback?,
        },
      )

      [adjusted_turn_ids, adjusted_summary_text]
    rescue StandardError
      [compacted_turn_ids, summary_text]
    end

    def compact_context_input(estimated:, budget:)
      AgentCore::RuntimeSurface::Inputs::CompactContext.new(
        context_window: transcript_nodes,
        budget: {
          estimated_tokens: estimated,
          limit: budget,
        },
        capabilities: {
          strategy: strategy,
        },
        helpers: nil,
      )
    end

    def apply_kept_items(decision:, compacted_turn_ids:, budget:)
      kept_turn_ids =
        Array(decision.kept_items).filter_map do |item|
          if item.is_a?(Hash)
            item.fetch("turn_id", item.fetch(:turn_id, nil)).to_s.presence
          else
            item.to_s.presence
          end
        end.uniq

      return [compacted_turn_ids, nil] if kept_turn_ids.empty?

      adjusted_turn_ids = compacted_turn_ids - kept_turn_ids
      return [compacted_turn_ids, false] if adjusted_turn_ids.empty?

      estimate =
        estimated_tokens_for(
          context_nodes:
            transcript_nodes.reject { |node| adjusted_turn_ids.include?(node.fetch("turn_id").to_s) } + [synthetic_user_node],
        )

      estimate <= budget ? [adjusted_turn_ids, true] : [compacted_turn_ids, false]
    rescue StandardError
      [compacted_turn_ids, false]
    end

    def summary_text_from_decision(decision)
      Array(decision.summaries).each do |summary|
        text =
          if summary.is_a?(Hash)
            summary.fetch("content", summary.fetch(:content, nil)).to_s
          else
            summary.to_s
          end

        return text if text.present?
      end

      nil
    rescue StandardError
      nil
    end

    def compacted_line_for(node)
      payload = node.fetch("payload", {})
      input = payload.fetch("input", {})
      output = payload.fetch("output", {})
      output_preview = payload.fetch("output_preview", {})
      node_type = node.fetch("node_type").to_s

      content =
        case node_type
        when Messages::UserMessage.node_type_key
          input.fetch("content", "").to_s
        when Messages::AgentMessage.node_type_key, "character_message", Messages::ProductMessage.node_type_key, Messages::Summary.node_type_key
          output.fetch("content", output_preview.fetch("content", "")).to_s
        when Messages::Task.node_type_key
          tool_result_text_for_task(output: output, output_preview: output_preview)
        else
          input.fetch("content", output.fetch("content", output_preview.fetch("content", ""))).to_s
        end

      content = content.squish
      return nil if content.blank?

      "#{role_label_for(node_type, input: input)}: #{content.truncate(240)}"
    end

    def role_label_for(node_type, input:)
      case node_type
      when Messages::UserMessage.node_type_key
        "User"
      when Messages::AgentMessage.node_type_key, "character_message"
        "Assistant"
      when Messages::Task.node_type_key
        name = input.fetch("name", "").to_s.strip
        name.present? ? "Task(#{name})" : "Task"
      when Messages::ProductMessage.node_type_key
        "Product"
      when Messages::Summary.node_type_key
        "Summary"
      else
        node_type
      end
    end

    def tool_result_text_for_task(output:, output_preview:)
      result = output.fetch("result", nil)
      return output_preview.fetch("result", "").to_s unless result

      AgentCore::Resources::Tools::ToolResult.from_h(result).text.to_s
    rescue StandardError
      output_preview.fetch("result", "").to_s
    end

    def truncate_to_token_limit(text, token_limit:)
      return "" if token_limit <= 0
      return text if token_counter.count_text(text) <= token_limit

      left = 0
      right = text.length
      best = +""

      while left <= right
        middle = (left + right) / 2
        candidate = "#{text[0, middle].to_s.rstrip}..."
        if token_counter.count_text(candidate) <= token_limit
          best = candidate
          left = middle + 1
        else
          right = middle - 1
        end
      end

      best
    end

    def synthetic_user_node
      {
        "node_id" => "synthetic-user",
        "turn_id" => "synthetic-turn",
        "lane_id" => @conversation.chat_lane.id,
        "node_type" => Messages::UserMessage.node_type_key,
        "state" => DAG::Node::FINISHED,
        "payload" => {
          "input" => { "content" => @content },
          "output" => {},
          "output_preview" => {},
        },
        "metadata" => {},
      }
    end

    def estimated_tokens_for(context_nodes:)
      adapted = AgentCore::DAG::ContextAdapter.new(context_nodes: context_nodes).call
      token_counter.count_text(adapted.system_prompt.to_s) + token_counter.count_messages(adapted.messages)
    end

    def effective_prompt_budget_tokens
      [(model_spec.fetch("context_window_tokens").to_i - reserved_output_tokens), 1].max
    end

    def reserved_output_tokens
      0
    end

    def token_counter
      @token_counter ||=
        AgentCore::Resources::TokenCounter::Estimator.new(
          token_estimator: Cybros::TokenEstimation.estimator(tokenizer_root_path: Cybros::TokenEstimation.tokenizer_root, strict: false),
          model_hint: model_spec.fetch("tokenizer_hint", model_spec.fetch("api_model")).to_s,
        )
    end

    def runtime_surface_resolution
      @runtime_surface_resolution ||=
        Cybros::AgentRuntimeResolver.runtime_surface_resolution_for(
          conversation: @conversation,
          token_counter: token_counter,
        )
    rescue StandardError
      nil
    end

    def model_spec
      @model_spec ||=
        begin
          resolution = Cybros::AgentRuntimeResolver.model_resolution_for(conversation: @conversation)
          Cybros::LLM::Catalog.effective.model(
            resolution.fetch(:provider_key),
            resolution.fetch(:model_key),
          )
        end
    end
end
