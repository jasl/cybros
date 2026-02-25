module DAG
  class TranscriptProjection
    def initialize(graph:)
      @graph = graph
    end

    def project(node_records:, mode:)
      node_records = Array(node_records)

      bodies = load_bodies(node_records: node_records, mode: mode)

      context_nodes =
        node_records.map do |node|
          body = bodies[node.body_id]
          context_hash_for(node: node, body: body, mode: mode)
        end

      apply_rules(context_nodes: context_nodes)
    end

    def apply_rules(context_nodes:)
      transcript = Array(context_nodes).select { |context_node| @graph.transcript_include?(context_node) }
      apply_preview_overrides!(transcript)
      transcript
    end

    private

      def load_bodies(node_records:, mode:)
        body_ids = node_records.map(&:body_id).compact.uniq
        if body_ids.empty?
          {}
        else
          body_scope = DAG::NodeBody.where(id: body_ids)
          body_scope =
            if mode.to_sym == :full
              body_scope.select(:id, :type, :input, :output, :output_preview)
            else
              body_scope.select(:id, :type, :input, :output_preview)
            end

          body_scope.index_by(&:id)
        end
      end

      def context_hash_for(node:, body:, mode:)
        payload_hash = {
          "input" => body&.input.is_a?(Hash) ? body.input : {},
          "output_preview" => body&.output_preview.is_a?(Hash) ? body.output_preview : {},
        }

        if mode.to_sym == :full
          payload_hash["output"] = body&.output.is_a?(Hash) ? body.output : {}
        end

        {
          "node_id" => node.id,
          "turn_id" => node.turn_id,
          "lane_id" => node.lane_id,
          "node_type" => node.node_type,
          "state" => node.state,
          "payload" => payload_hash,
          "metadata" => node.metadata,
        }
      end

      def apply_preview_overrides!(transcript)
        transcript.each do |context_node|
          payload = context_node["payload"].is_a?(Hash) ? context_node["payload"] : {}
          output_preview = payload["output_preview"].is_a?(Hash) ? payload["output_preview"] : {}
          next if output_preview["content"].to_s.present?

          override = @graph.transcript_preview_override(context_node)
          next unless override.is_a?(String) && override.present?

          output_preview["content"] = override
          payload["output_preview"] = output_preview
          context_node["payload"] = payload
        end
      end
  end
end
