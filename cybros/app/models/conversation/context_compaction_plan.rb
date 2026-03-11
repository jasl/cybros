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

  def self.plan(conversation:, content:, lane: nil, runtime_surface_resolution: nil, runtime: nil)
    new(
      conversation: conversation,
      content: content,
      lane: lane,
      runtime_surface_resolution: runtime_surface_resolution,
      runtime: runtime,
    ).plan
  end

  def initialize(conversation:, content:, lane: nil, runtime_surface_resolution: nil, runtime: nil)
    @conversation = conversation
    @content = content.to_s
    @lane = lane || conversation.chat_lane
    @runtime_surface_resolution = runtime_surface_resolution
    @runtime = runtime
  end

  def plan
    hard_budget = effective_prompt_budget_tokens
    compaction_budget = compaction_target_tokens(hard_budget: hard_budget)
    estimated = estimated_tokens_for(context_nodes: transcript_nodes + [synthetic_user_node])

    return build_result(required: false, estimated: estimated, budget: hard_budget) if estimated <= compaction_budget

    compacted_turn_ids = compacted_turn_ids_for(budget: compaction_budget)
    return build_result(required: false, estimated: estimated, budget: hard_budget) if compacted_turn_ids.empty?

    compacted_nodes = transcript_nodes.select { |node| compacted_turn_ids.include?(node.fetch("turn_id").to_s) }
    summary_text = summary_text_for(compacted_nodes: compacted_nodes, budget: compaction_budget)
    compacted_turn_ids, summary_text =
      apply_runtime_surface_compaction(
        compacted_turn_ids: compacted_turn_ids,
        summary_text: summary_text,
        estimated: estimated,
        budget: compaction_budget,
      )

    build_result(
      required: true,
      estimated: estimated,
      budget: hard_budget,
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

    def transcript_nodes
      @transcript_nodes ||= lane.transcript_recent_turns(limit_turns: Cybros::AgentRuntimeResolver::MAX_CONTEXT_TURNS, mode: :full)
    end

    def compacted_turn_ids_for(budget:)
      turn_ids = transcript_nodes.filter_map { |node| node.fetch("turn_id").to_s.presence }.uniq
      return [] if turn_ids.length <= 1

      latest_turn_id = turn_ids.last
      kept_turn_ids = turn_ids.dup
      compacted_turn_ids = []

      while kept_turn_ids.length > 1
        estimate =
          estimated_tokens_for(
            context_nodes:
              transcript_nodes.select { |node| kept_turn_ids.include?(node.fetch("turn_id").to_s) } + [synthetic_user_node],
          )
        break if estimate <= budget

        candidate_turn_id = kept_turn_ids.shift
        next if candidate_turn_id == latest_turn_id

        compacted_turn_ids << candidate_turn_id
      end

      compacted_turn_ids
    end

    def summary_text_for(compacted_nodes:, budget:)
      lines = compacted_nodes.filter_map { |node| compacted_line_for(node) }
      summary_body =
        if lines.any?
          lines.join("\n")
        else
          "Older conversation context was compacted before this turn."
        end

      text = "[Compacted prior context]\n#{summary_body}"

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
          strategy: "compact_context",
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
        "lane_id" => lane.id,
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
      prompt_buffer_tokens =
        AgentCore::DAG::LanePromptBufferSections.new(lane: lane).sections.sum do |section|
          token_counter.count_text(section.content.to_s)
        end

      token_counter.count_text(adapted.system_prompt.to_s) + prompt_buffer_tokens + token_counter.count_messages(adapted.messages)
    end

    def lane
      @lane
    end

    def effective_prompt_budget_tokens
      window_tokens = runtime_context_window_tokens || model_spec.fetch("context_window_tokens").to_i
      [(window_tokens - reserved_output_tokens), 1].max
    end

    def reserved_output_tokens
      return @runtime.reserved_output_tokens.to_i if @runtime.respond_to?(:reserved_output_tokens)

      0
    end

    def token_counter
      @token_counter ||= @runtime&.token_counter ||
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

    def runtime_context_window_tokens
      return nil unless @runtime.respond_to?(:context_window_tokens)

      value = @runtime.context_window_tokens
      value.present? ? value.to_i : nil
    end

    def compaction_target_tokens(hard_budget:)
      soft_budget = effective_context_soft_limit_tokens(limit: hard_budget)
      soft_budget || hard_budget
    end

    def effective_context_soft_limit_tokens(limit:)
      return nil if limit.nil?

      token_limit =
        if @runtime.respond_to?(:context_soft_limit_tokens) && @runtime.context_soft_limit_tokens.present?
          @runtime.context_soft_limit_tokens.to_i
        end
      ratio_limit =
        if @runtime.respond_to?(:context_soft_limit_ratio) && @runtime.context_soft_limit_ratio.present?
          (limit * @runtime.context_soft_limit_ratio.to_f).floor
        end

      soft_limit = [token_limit, ratio_limit].compact.min
      return nil if soft_limit.nil?

      [soft_limit, limit].min
    end
end
