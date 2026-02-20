require "digest"

module DAG
  class NodeEventRetention
    class << self
      def compact_output_deltas!(node:, content:)
        content = content.to_s

        deleted =
          DAG::NodeEvent.where(
            graph_id: node.graph_id,
            node_id: node.id,
            kind: DAG::NodeEvent::OUTPUT_DELTA
          ).delete_all

        return 0 if deleted == 0

        sha256 = Digest::SHA256.hexdigest(content)

        DAG::NodeEvent.create!(
          graph_id: node.graph_id,
          node_id: node.id,
          kind: DAG::NodeEvent::OUTPUT_COMPACTED,
          text: nil,
          payload: {
            "chunks" => deleted,
            "bytes" => content.bytesize,
            "sha256" => sha256,
            "source_kind" => DAG::NodeEvent::OUTPUT_DELTA,
            "compacted_at" => Time.current.iso8601,
          }
        )

        deleted
      end
    end
  end
end
