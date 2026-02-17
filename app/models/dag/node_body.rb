module DAG
  class NodeBody < ApplicationRecord
    self.table_name = "dag_node_bodies"

    has_one :node,
            class_name: "DAG::Node",
            inverse_of: :body,
            foreign_key: :body_id

    PREVIEW_MAX_CHARS = 200

    before_validation :normalize_jsonb_fields
    before_validation :sync_output_preview

    def retriable?
      false
    end

    def editable?
      false
    end

    def regeneratable?
      false
    end

    def preview_max_chars
      PREVIEW_MAX_CHARS
    end

    def merge_input!(patch)
      patch = normalize_patch(patch)
      self.input = normalized_input.deep_merge(patch)
    end

    def merge_output!(patch)
      patch = normalize_patch(patch)
      self.output = normalized_output.deep_merge(patch)
      sync_output_preview
    end

    def apply_finished_content!(content)
      merge_output!("content" => content)
    end

    def input_for_retry
      normalized_input.deep_dup
    end

    private

      def sync_output_preview
        self.output_preview = preview_from_output(normalized_output)
      end

      def preview_from_output(output_hash)
        return {} unless output_hash.is_a?(Hash)

        if output_hash.key?("content")
          { "content" => truncate_preview_value(output_hash["content"]) }
        elsif output_hash.key?("result")
          { "result" => truncate_preview_value(output_hash["result"]) }
        elsif output_hash.length == 1
          key, value = output_hash.first
          { key => truncate_preview_value(value) }
        elsif output_hash.any?
          { "json" => truncate_preview_string(output_hash.to_json) }
        else
          {}
        end
      end

      def truncate_preview_value(value)
        case value
        when String
          truncate_preview_string(value)
        else
          truncate_preview_string(value.to_json)
        end
      end

      def truncate_preview_string(string)
        string.to_s.truncate(preview_max_chars)
      end

      def normalize_jsonb_fields
        self.input = {} unless input.is_a?(Hash)
        self.output = {} unless output.is_a?(Hash)
        self.output_preview = {} unless output_preview.is_a?(Hash)
      end

      def normalize_patch(patch)
        if patch.is_a?(Hash)
          patch.deep_stringify_keys
        else
          {}
        end
      end

      def normalized_input
        if input.is_a?(Hash)
          input
        else
          {}
        end
      end

      def normalized_output
        if output.is_a?(Hash)
          output
        else
          {}
        end
      end
  end
end
