require "digest"

module Agents
  class Creator
    def self.create_from_bundled_source!(name:, bundled_agent_key:)
      source_dir = BundledSources.path_for(bundled_agent_key)
      raise ArgumentError, "unknown bundled source" if source_dir.nil?

      loaded = Loader.new(base_dir: source_dir).load
      manifest = loaded.manifest
      manifest_key = manifest.fetch("agent_key", manifest.fetch(legacy_manifest_agent_key))
      retries = 0

      begin
        agent = Agent.find_by(source_kind: "bundled", bundled_agent_key: bundled_agent_key.to_s) ||
          Agent.find_by(config_namespace: manifest["config_namespace"].presence || "bundled.#{manifest_key}") ||
          Agent.new(source_kind: "bundled", bundled_agent_key: bundled_agent_key.to_s)
        persisted_name = agent.name.to_s.strip.presence

        agent.assign_attributes(
          source_kind: "bundled",
          bundled_agent_key: bundled_agent_key.to_s,
          name: persisted_name || name.presence || manifest.fetch("name", "Bundled agent"),
          description: manifest["description"],
          local_path: BundledSources.relative_path_for(bundled_agent_key),
          manifest_snapshot: manifest,
          config_namespace: manifest["config_namespace"].presence || "bundled.#{manifest_key}",
          published_contract_fingerprint: bundled_contract_fingerprint(manifest),
          global_config: {},
          global_config_schema: manifest.fetch("global_config_schema", {}),
          conversation_config_schema: manifest.fetch("conversation_config_schema", {}),
          config_schema_fingerprint: bundled_config_schema_fingerprint(manifest),
          args: {
            "runtime_surface" => loaded.runtime_surface_config,
            "runtime_surface_status" => loaded.runtime_surface_status,
          },
          max_concurrent_tasks: agent.max_concurrent_tasks || default_max_concurrent_tasks,
          max_queued_tasks: agent.max_queued_tasks || default_max_queued_tasks(agent.max_concurrent_tasks || default_max_concurrent_tasks),
          default_timeout_s: agent.default_timeout_s || Agent::DEFAULT_EXECUTION_TIMEOUT_S,
        )
        agent.save!
        agent
      rescue ActiveRecord::RecordNotUnique
        raise if (retries += 1) > 2

        retry
      end
    end

    def self.bundled_contract_fingerprint(manifest)
      payload = manifest.is_a?(Hash) ? manifest.deep_stringify_keys : {}
      "contract:sha256:#{Digest::SHA256.hexdigest(payload.to_json)}"
    end

    def self.bundled_config_schema_fingerprint(manifest)
      payload = {
        "global_config_schema" => manifest.fetch("global_config_schema", {}),
        "conversation_config_schema" => manifest.fetch("conversation_config_schema", {}),
      }
      "config:sha256:#{Digest::SHA256.hexdigest(payload.to_json)}"
    end

    def self.default_max_concurrent_tasks
      RuntimeSetting.find_by(scope_key: "instance")&.default_worker_concurrency.presence || RuntimeSetting::DEFAULT_WORKER_CONCURRENCY
    end

    def self.default_max_queued_tasks(max_concurrent_tasks)
      max_concurrent_tasks.to_i * Agent::DEFAULT_EXECUTION_CAPACITY_QUEUE_MULTIPLIER
    end

    def self.legacy_manifest_agent_key
      @legacy_manifest_agent_key ||= %w[agent program key].join("_")
    end
  end
end
