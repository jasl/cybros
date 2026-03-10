require "fileutils"

module AgentPrograms
  class Creator
    STORAGE_ROOT = Rails.root.join("storage", "agent_programs").freeze

    def self.create_from_bundled_source!(name:, bundled_agent_key:)
      source_dir = BundledSources.path_for(bundled_agent_key)
      raise ArgumentError, "unknown bundled source" if source_dir.nil?

      loaded = Loader.new(base_dir: source_dir).load
      manifest = loaded.manifest
      manifest_key = manifest.fetch("agent_program_key")

      program = AgentProgram.find_or_initialize_by(source_kind: "bundled", bundled_agent_key: bundled_agent_key.to_s)
      program.assign_attributes(
        name: name.presence || manifest.fetch("name", "Bundled agent"),
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
        active_persona: nil,
      )
      program.save!
      program
    end

    def self.create_from_profile!(name:, profile_source:)
      legacy_key =
        case profile_source.to_s
        when "default-assistant", "default"
          "default"
        else
          raise ArgumentError, "unknown bundled profile"
        end

      create_from_bundled_source!(name: name, bundled_agent_key: legacy_key)
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
  end
end
