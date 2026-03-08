class AgentProgram < ApplicationRecord
  validates :name, presence: true

  def bundled_profile?
    profile_source.to_s.strip != ""
  end

  def runtime_surface_config
    stored = runtime_surface_snapshot.fetch("runtime_surface", nil)
    stored.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(stored) : default_runtime_surface_config
  rescue StandardError
    default_runtime_surface_config
  end

  def runtime_surface_status
    status = runtime_surface_snapshot.fetch("runtime_surface_status", nil).to_s
    return status if %w[configured missing invalid].include?(status)

    loaded_program.runtime_surface_status
  rescue StandardError
    "missing"
  end

  def runtime_surface_fallback?
    runtime_surface_status != "configured"
  end

  def runtime_surface_label
    label = runtime_surface_config.fetch("type", "noop").to_s
    runtime_surface_fallback? ? "#{label} (fallback)" : label
  end

  def refresh_runtime_surface_snapshot(loader: nil)
    loaded = loader || loaded_program
    current = args.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(args) : {}
    current["runtime_surface"] = loaded.runtime_surface_config
    current["runtime_surface_status"] = loaded.runtime_surface_status
    current
  rescue StandardError
    {
      "runtime_surface" => default_runtime_surface_config,
      "runtime_surface_status" => "missing",
    }
  end

  def loaded_program(loader: nil)
    loader ||= AgentPrograms::Loader.new(base_dir: absolute_local_path)
    loader.load
  end

  def absolute_local_path
    Rails.root.join(local_path.to_s)
  end

  private

    def runtime_surface_snapshot
      current = args.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(args) : {}
      return current if current["runtime_surface"].is_a?(Hash) && current["runtime_surface_status"].present?

      loaded_program.then do |loaded|
        {
          "runtime_surface" => loaded.runtime_surface_config,
          "runtime_surface_status" => loaded.runtime_surface_status,
        }
      end
    rescue StandardError
      {
        "runtime_surface" => default_runtime_surface_config,
        "runtime_surface_status" => "missing",
      }
    end

    def default_runtime_surface_config
      Cybros::AgentProfileConfig.default_runtime_surface_metadata
    end
end
