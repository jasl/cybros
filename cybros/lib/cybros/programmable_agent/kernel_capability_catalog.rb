require "digest"
require "json"

module Cybros
  module ProgrammableAgent
    KernelCapabilityCatalog =
      Data.define(
        :kernel_capability_registry_version,
        :tools,
      ) do
        def self.current
          tool_names = Cybros::AgentRuntimeResolver.send(:build_tools_registry).tool_names.sort
          payload = { tools: tool_names }
          version = "kernel:sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload)).first(24)}"
          tools = tool_names.map { |tool_name| { logical_tool_name: tool_name, implementation_ref: "kernel://#{tool_name}" } }

          new(
            kernel_capability_registry_version: version,
            tools: tools,
          )
        end
      end
  end
end
