module Messages
  class ToolCall < ::DAG::NodeBody
    def retriable?
      true
    end

    def apply_finished_content!(content)
      merge_output!("result" => content)
    end

    private

      def preview_from_output(output_hash)
        return {} unless output_hash.is_a?(Hash)

        if output_hash.key?("result")
          { "result" => summarize_result_preview(output_hash["result"]) }
        else
          super
        end
      end

      def summarize_result_preview(value)
        case value
        when String
          truncate_preview_string(value)
        when Hash
          keys = value.each_key.take(20).map { |key| key.to_s }
          summary = +"Hash(size=#{value.size}; keys=#{keys.join(",")}"
          summary << ",…" if value.size > keys.length
          summary << ")"
          truncate_preview_string(summary)
        when Array
          sample = value.first(10).map { |element| summarize_result_sample(element) }
          summary = +"Array(len=#{value.length}; sample=[#{sample.join(", ")}]"
          summary << ", …" if value.length > sample.length
          summary << ")"
          truncate_preview_string(summary)
        else
          truncate_preview_string(value.inspect)
        end
      end

      def summarize_result_sample(value)
        case value
        when String
          value.truncate(30)
        when Numeric, TrueClass, FalseClass, NilClass
          value.inspect
        when Hash
          "Hash"
        when Array
          "Array"
        else
          value.class.name
        end
      end
  end
end
