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

  def self.plan(conversation:, content:, input_policy:)
    new(conversation: conversation, content: content, input_policy: input_policy).plan
  end

  def initialize(conversation:, content:, input_policy:)
    @conversation = conversation
    @content = content.to_s
    @input_policy = input_policy.is_a?(Hash) ? input_policy : {}
  end

  def plan
    budget = effective_prompt_budget_tokens
    estimated = estimated_tokens_for(context_nodes: transcript_nodes + [synthetic_user_node])

    return build_result(required: false, estimated: estimated, budget: budget) unless strategy == "compact_context"
    return build_result(required: false, estimated: estimated, budget: budget) if estimated <= budget

    compacted_turn_ids = compacted_turn_ids_for(budget: budget)
    return build_result(required: false, estimated: estimated, budget: budget) if compacted_turn_ids.empty?

    compacted_nodes = transcript_nodes.select { |node| compacted_turn_ids.include?(node.fetch("turn_id").to_s) }

    build_result(
      required: true,
      estimated: estimated,
      budget: budget,
      compacted_turn_ids: compacted_turn_ids,
      summary_text: summary_text_for(compacted_nodes: compacted_nodes, budget: budget),
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
