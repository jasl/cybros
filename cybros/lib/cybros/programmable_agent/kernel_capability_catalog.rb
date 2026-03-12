require "digest"
require "json"

module Cybros
  module ProgrammableAgent
    KernelCapabilityCatalog =
      Data.define(
        :kernel_capability_registry_version,
        :tools,
      ) do
        EXECUTION_MODES = %w[serial parallel_safe].freeze

        def self.current
          registry = Cybros::AgentRuntimeResolver.send(:build_tools_registry)
          tool_names = registry.tool_names.sort
          tools =
            tool_names.map do |tool_name|
              tool = registry.find(tool_name)
              {
                logical_tool_name: tool_name,
                implementation_ref: "kernel://#{tool_name}",
                execution_mode: execution_mode_for(tool),
              }
            end
          payload = { tools: tools }
          version = "kernel:sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload)).first(24)}"

          new(
            kernel_capability_registry_version: version,
            tools: tools,
          )
        end

        def self.execution_mode_for(tool)
          mode =
            if tool.respond_to?(:metadata)
              tool.metadata[:execution_mode] || tool.metadata["execution_mode"]
            end

          mode = mode.to_s.presence || "serial"
          return mode if EXECUTION_MODES.include?(mode)

          AgentCore::ValidationError.raise!(
            "kernel tool execution_mode must be supported",
            code: "cybros.programmable_agent.kernel_capability_catalog.execution_mode_must_be_supported",
            details: {
              logical_tool_name: tool.respond_to?(:name) ? tool.name : nil,
              execution_mode: mode,
            }.compact,
          )
        end
      end
  end
end
