require "digest"
require "json"
require "yaml"

class RebaselineBundledDefaultAgentProgram < ActiveRecord::Migration[8.2]
  LEGACY_PROFILE_SOURCES = %w[default default-assistant].freeze

  def up
    canonical = ensure_canonical_default_program
    backfill_nil_conversations(canonical) if canonical
    repoint_live_legacy_selections(canonical) if canonical

    remove_column :agent_programs, :profile_source, :string, if_exists: true
    remove_column :agent_programs, :active_persona, :string, if_exists: true
  end

  def down
    add_column :agent_programs, :profile_source, :string unless column_exists?(:agent_programs, :profile_source)
    add_column :agent_programs, :active_persona, :string unless column_exists?(:agent_programs, :active_persona)
  end

  private

    def ensure_canonical_default_program
      existing_default_program || canonicalized_legacy_default_program
    end

    def existing_default_program
      select_one(<<~SQL.squish)
        SELECT id, config_schema_fingerprint
        FROM agent_programs
        WHERE source_kind = 'bundled' AND bundled_agent_key = 'default'
        ORDER BY created_at ASC
        LIMIT 1
      SQL
    end

    def canonicalized_legacy_default_program
      legacy = select_one(<<~SQL.squish)
        SELECT id
        FROM agent_programs
        WHERE profile_source IN (#{quoted_legacy_profile_sources})
        ORDER BY created_at ASC
        LIMIT 1
      SQL
      return nil unless legacy

      manifest = bundled_default_manifest
      runtime_surface = normalized_runtime_surface_payload(manifest)

      execute <<~SQL.squish
        UPDATE agent_programs
        SET source_kind = 'bundled',
            bundled_agent_key = 'default',
            local_path = 'agents/default',
            name = #{quote(manifest.fetch("name", "Default"))},
            description = #{quote(manifest["description"])},
            manifest_snapshot = #{quote_json(manifest)},
            config_namespace = #{quote(manifest.fetch("config_namespace", "bundled.default"))},
            published_contract_fingerprint = #{quote(contract_fingerprint_for(manifest))},
            config_schema_fingerprint = #{quote(config_schema_fingerprint_for(manifest))},
            global_config = #{quote_json({})},
            global_config_schema = #{quote_json(manifest.fetch("global_config_schema", {}))},
            conversation_config_schema = #{quote_json(manifest.fetch("conversation_config_schema", {}))},
            args = #{quote_json(runtime_surface)},
            updated_at = CURRENT_TIMESTAMP
        WHERE id = #{quote(legacy.fetch("id"))}
      SQL

      existing_default_program
    end

    def backfill_nil_conversations(canonical)
      execute <<~SQL.squish
        UPDATE conversations
        SET agent_program_id = #{quote(canonical.fetch("id"))},
            agent_config_schema_fingerprint = #{quote(canonical.fetch("config_schema_fingerprint"))},
            updated_at = CURRENT_TIMESTAMP
        WHERE agent_program_id IS NULL
      SQL
    end

    def repoint_live_legacy_selections(canonical)
      legacy_ids =
        select_values(<<~SQL.squish)
          SELECT id
          FROM agent_programs
          WHERE id <> #{quote(canonical.fetch("id"))}
            AND profile_source IN (#{quoted_legacy_profile_sources})
        SQL
      return if legacy_ids.empty?

      quoted_ids = legacy_ids.map { |id| quote(id) }.join(", ")

      execute <<~SQL.squish
        UPDATE conversations
        SET agent_program_id = #{quote(canonical.fetch("id"))},
            agent_config_schema_fingerprint = #{quote(canonical.fetch("config_schema_fingerprint"))},
            updated_at = CURRENT_TIMESTAMP
        WHERE agent_program_id IN (#{quoted_ids})
      SQL

      execute <<~SQL.squish
        UPDATE automations
        SET agent_program_id = #{quote(canonical.fetch("id"))},
            updated_at = CURRENT_TIMESTAMP
        WHERE agent_program_id IN (#{quoted_ids})
      SQL

      execute <<~SQL.squish
        UPDATE agent_programs
        SET forked_from_agent_program_id = #{quote(canonical.fetch("id"))},
            updated_at = CURRENT_TIMESTAMP
        WHERE forked_from_agent_program_id IN (#{quoted_ids})
      SQL
    end

    def bundled_default_manifest
      path = Rails.root.join("agents", "default", "agent.yml")
      raw = path.read
      parsed = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: false)
      parsed.is_a?(Hash) ? deep_stringify_keys(parsed) : {}
    rescue StandardError
      {}
    end

    def contract_fingerprint_for(manifest)
      payload = manifest.is_a?(Hash) ? deep_stringify_keys(manifest) : {}
      "contract:sha256:#{Digest::SHA256.hexdigest(payload.to_json)}"
    end

    def config_schema_fingerprint_for(manifest)
      payload = {
        "global_config_schema" => manifest.fetch("global_config_schema", {}),
        "conversation_config_schema" => manifest.fetch("conversation_config_schema", {}),
      }
      "config:sha256:#{Digest::SHA256.hexdigest(payload.to_json)}"
    end

    def normalized_runtime_surface_payload(manifest)
      raw = manifest.fetch("runtime_surface", nil)
      present = manifest.key?("runtime_surface")
      config = normalize_runtime_surface_metadata(raw)

      {
        "runtime_surface" => config,
        "runtime_surface_status" => present ? "configured" : "missing",
      }
    end

    def normalize_runtime_surface_metadata(value)
      return default_runtime_surface_metadata unless value.is_a?(Hash)

      cfg = deep_stringify_keys(value)
      type = cfg.fetch("type", "noop").to_s.strip.downcase.tr("-", "_")
      return default_runtime_surface_metadata unless type == "noop"

      {
        "type" => "noop",
        "helpers" => normalize_runtime_surface_helpers(cfg.fetch("helpers", {})),
        "stage_limits" => normalize_runtime_surface_stage_limits(cfg.fetch("stage_limits", {})),
      }
    rescue StandardError
      default_runtime_surface_metadata
    end

    def normalize_runtime_surface_helpers(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(helper_name, enabled), out|
        next unless helper_name.to_s.strip.downcase.tr("-", "_") == "estimate_tokens"
        next unless enabled == true

        out["estimate_tokens"] = true
      end
    end

    def normalize_runtime_surface_stage_limits(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(stage_name, stage_cfg), out|
        key = stage_name.to_s.strip.downcase.tr("-", "_")
        next unless %w[prepare_turn compact_context review_tool_call project_tool_result finalize_output handle_error].include?(key)
        next unless stage_cfg.is_a?(Hash)

        entry = {}
        timeout_s = Float(stage_cfg["timeout_s"], exception: false)
        entry["timeout_s"] = timeout_s if timeout_s&.positive? && timeout_s.finite?

        max_output_bytes = Integer(stage_cfg["max_output_bytes"], exception: false)
        entry["max_output_bytes"] = max_output_bytes if max_output_bytes&.positive?

        out[key] = entry if entry.any?
      end
    end

    def default_runtime_surface_metadata
      {
        "type" => "noop",
        "helpers" => {},
        "stage_limits" => {},
      }
    end

    def deep_stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, inner), out|
          out[key.to_s] = deep_stringify_keys(inner)
        end
      when Array
        value.map { |inner| deep_stringify_keys(inner) }
      else
        value
      end
    end

    def quoted_legacy_profile_sources
      LEGACY_PROFILE_SOURCES.map { |value| quote(value) }.join(", ")
    end

    def quote_json(value)
      quote(JSON.generate(value))
    end
end
