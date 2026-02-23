# frozen_string_literal: true

module AgentCore
  module DAG
    class ExecutionContextBuilder
      CHANNEL_MAX_BYTES = 128

      def self.build(node:, runtime:)
        attrs = runtime.execution_context_attributes
        attrs = attrs.is_a?(Hash) ? attrs.dup : {}

        workspace_dir = attrs[:workspace_dir].to_s.strip
        workspace_dir = Dir.pwd if workspace_dir.empty?

        cwd = attrs[:cwd].to_s.strip
        cwd = workspace_dir if cwd.empty?

        channel = attrs[:channel].to_s
        channel = channel.lines.first.to_s.strip

        attrs[:workspace_dir] = workspace_dir
        attrs[:cwd] = cwd
        attrs[:agent] = attrs[:agent].is_a?(Hash) ? attrs[:agent] : {}

        if channel.empty?
          attrs.delete(:channel)
        else
          attrs[:channel] = AgentCore::Utils.truncate_utf8_bytes(channel, max_bytes: CHANNEL_MAX_BYTES)
        end

        dag = attrs[:dag]
        dag = dag.is_a?(Hash) ? dag.dup : {}
        dag[:graph_id] = node.graph_id.to_s
        dag[:node_id] = node.id.to_s
        dag[:lane_id] = node.lane_id.to_s
        dag[:turn_id] = node.turn_id.to_s
        attrs[:dag] = dag

        ExecutionContext.new(
          run_id: node.turn_id.to_s,
          instrumenter: runtime.instrumenter,
          attributes: attrs,
        )
      end
    end
  end
end
