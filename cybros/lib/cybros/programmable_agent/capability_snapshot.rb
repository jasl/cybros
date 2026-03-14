require "digest"
require "json"

module Cybros
  module ProgrammableAgent
    EffectiveTool =
      Data.define(
        :logical_tool_name,
        :effective_tool_id,
        :implementation_source,
        :implementation_ref,
        :execution_mode,
      )

    class CapabilitySnapshot
      RESERVED_LOGICAL_NAME_PREFIX = "cybros_".freeze
      EFFECTIVE_TOOL_ID_PREFIX = "etool_".freeze
      SNAPSHOT_ID_PREFIX = "csnap_".freeze
      EXECUTION_MODES = %w[serial parallel_safe].freeze

      attr_reader :agent_key, :agent_capabilities_version, :effective_tools, :kernel_registry_version, :snapshot_id

      def self.build(**attributes)
        new(**attributes)
      end

      def self.normalize_execution_mode(value)
        mode = value.to_s.presence || "serial"
        return mode if EXECUTION_MODES.include?(mode)

        AgentCore::ValidationError.raise!(
          "execution_mode must be one of #{EXECUTION_MODES.join(", ")}",
          code: "cybros.programmable_agent.capability_snapshot.execution_mode_must_be_supported",
          details: { execution_mode: value },
        )
      end

      def self.restore(payload)
        normalized = payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
        snapshot_id = normalized.fetch(:capability_registry_snapshot_id, normalized.fetch(:snapshot_id, "")).to_s

        AgentCore::ValidationError.raise!(
          "capability_registry_snapshot_id is required",
          code: "cybros.programmable_agent.capability_snapshot.capability_registry_snapshot_id_is_required",
        ) if snapshot_id.empty?

        effective_tools =
          Array(normalized.fetch(:effective_tools, [])).map do |tool|
            attributes = tool.is_a?(Hash) ? tool.deep_symbolize_keys : {}

            EffectiveTool.new(
              logical_tool_name: attributes.fetch(:logical_tool_name, "").to_s,
              effective_tool_id: attributes.fetch(:effective_tool_id, "").to_s,
              implementation_source: attributes.fetch(:implementation_source, "").to_s,
              implementation_ref: attributes.fetch(:implementation_ref, "").to_s,
              execution_mode: normalize_execution_mode(attributes.fetch(:execution_mode, "serial")),
            )
          end

        instance = allocate
        instance.instance_variable_set(:@kernel_registry_version, normalized.fetch(:kernel_capability_registry_version, "").to_s.freeze)
        instance.instance_variable_set(:@agent_key, normalized.fetch(:agent_key, "").to_s.freeze)
        instance.instance_variable_set(:@agent_capabilities_version, normalized.fetch(:agent_capabilities_version, "").to_s.freeze)
        instance.instance_variable_set(:@effective_tools, effective_tools.freeze)
        instance.instance_variable_set(:@effective_tools_by_id, effective_tools.index_by(&:effective_tool_id).freeze)
        instance.instance_variable_set(:@routes_by_logical_name, effective_tools.index_by(&:logical_tool_name).freeze)
        instance.instance_variable_set(:@snapshot_id, snapshot_id.freeze)
        instance
      end

      def initialize(kernel_registry_version:, agent_key:, agent_capabilities_version:, kernel_tools:, agent_tools:)
        @kernel_registry_version = kernel_registry_version.to_s
        @agent_key = agent_key.to_s
        @agent_capabilities_version = agent_capabilities_version.to_s

        kernel_catalog = normalize_catalog(kernel_tools, implementation_source: "kernel")
        agent_catalog = normalize_catalog(agent_tools, implementation_source: "agent")
        reject_reserved_agent_tools!(agent_catalog)

        @effective_tools = merge_catalogs(kernel_catalog: kernel_catalog, agent_catalog: agent_catalog).freeze
        @effective_tools_by_id = @effective_tools.index_by(&:effective_tool_id).freeze
        @routes_by_logical_name = @effective_tools.index_by(&:logical_tool_name).freeze
        @snapshot_id = build_snapshot_id.freeze
      end

      def route_for(logical_tool_name)
        @routes_by_logical_name[logical_tool_name.to_s]
      end

      def route_for!(logical_tool_name)
        route_for(logical_tool_name) ||
          AgentCore::ValidationError.raise!(
            "logical tool is not present in capability snapshot",
            code: "cybros.programmable_agent.capability_snapshot.logical_tool_name_must_exist",
            details: { logical_tool_name: logical_tool_name.to_s, snapshot_id: snapshot_id },
          )
      end

      def effective_tool(effective_tool_id)
        @effective_tools_by_id[effective_tool_id.to_s]
      end

      private

        def normalize_catalog(tools, implementation_source:)
          Array(tools).map do |tool|
            normalized = tool.is_a?(Hash) ? tool.deep_symbolize_keys : {}
            logical_tool_name = normalized.fetch(:logical_tool_name, "").to_s
            implementation_ref = normalized.fetch(:implementation_ref, "").to_s

            AgentCore::ValidationError.raise!(
              "logical_tool_name is required",
              code: "cybros.programmable_agent.capability_snapshot.logical_tool_name_is_required",
              details: { implementation_source: implementation_source },
            ) if logical_tool_name.empty?

            AgentCore::ValidationError.raise!(
              "implementation_ref is required",
              code: "cybros.programmable_agent.capability_snapshot.implementation_ref_is_required",
              details: { logical_tool_name: logical_tool_name, implementation_source: implementation_source },
            ) if implementation_ref.empty?

            EffectiveTool.new(
              logical_tool_name: logical_tool_name,
              effective_tool_id: build_effective_tool_id(
                logical_tool_name: logical_tool_name,
                implementation_source: implementation_source,
                implementation_ref: implementation_ref,
              ),
              implementation_source: implementation_source,
              implementation_ref: implementation_ref,
              execution_mode: self.class.normalize_execution_mode(normalized.fetch(:execution_mode, "serial")),
            )
          end
        end

        def reject_reserved_agent_tools!(agent_catalog)
          reserved = agent_catalog.find { |tool| reserved_namespace?(tool.logical_tool_name) }
          return unless reserved

          AgentCore::ValidationError.raise!(
            "agent tools must not use the reserved cybros_* namespace",
            code: "cybros.programmable_agent.capability_snapshot.agent_tools_must_not_use_reserved_namespace",
            details: {
              logical_tool_name: reserved.logical_tool_name,
              implementation_ref: reserved.implementation_ref,
            },
          )
        end

        def merge_catalogs(kernel_catalog:, agent_catalog:)
          merged = {}

          kernel_catalog.each do |tool|
            merged[tool.logical_tool_name] = tool
          end

          agent_catalog.each do |tool|
            merged[tool.logical_tool_name] =
              if reserved_namespace?(tool.logical_tool_name)
                merged.fetch(tool.logical_tool_name, tool)
              else
                tool
              end
          end

          merged.values.sort_by(&:logical_tool_name)
        end

        def build_effective_tool_id(logical_tool_name:, implementation_source:, implementation_ref:)
          digest =
            Digest::SHA256.hexdigest(
              JSON.generate(
                {
                  logical_tool_name: logical_tool_name,
                  implementation_source: implementation_source,
                  implementation_ref: implementation_ref,
                },
              ),
            )
          "#{EFFECTIVE_TOOL_ID_PREFIX}#{digest.first(24)}"
        end

        def build_snapshot_id
          payload = {
            kernel_registry_version: kernel_registry_version,
            agent_key: agent_key,
            agent_capabilities_version: agent_capabilities_version,
            effective_tools:
              effective_tools.map do |tool|
                {
                  logical_tool_name: tool.logical_tool_name,
                  effective_tool_id: tool.effective_tool_id,
                  implementation_source: tool.implementation_source,
                  implementation_ref: tool.implementation_ref,
                  execution_mode: tool.execution_mode,
                }
              end,
          }

          "#{SNAPSHOT_ID_PREFIX}#{Digest::SHA256.hexdigest(JSON.generate(payload)).first(24)}"
        end

        def reserved_namespace?(logical_tool_name)
          logical_tool_name.start_with?(RESERVED_LOGICAL_NAME_PREFIX)
        end
    end
  end
end
