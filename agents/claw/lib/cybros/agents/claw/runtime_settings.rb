require "json"

module Cybros
  module Agents
    module Claw
      module RuntimeSettings
        module_function

        def skill_catalog_sources
          raw = ENV["CLAW_SKILL_CATALOG_SOURCES"].to_s.strip
          return [] if raw.empty?

          parsed = JSON.parse(raw)
          normalize_skill_catalog_sources(parsed)
        rescue JSON::ParserError => e
          ValidationError.raise!(
            "CLAW_SKILL_CATALOG_SOURCES must be valid JSON.",
            code: "claw.runtime_settings.invalid_skill_catalog_sources",
            details: { error: e.message },
          )
        end

        def platform_skill_dirs
          raw = ENV["CLAW_PLATFORM_SKILL_DIRS"].to_s
          dirs =
            raw.split(File::PATH_SEPARATOR).filter_map do |entry|
              normalized = entry.to_s.strip
              normalized.presence
            end

          if dirs.empty?
            default = Rails.root.join("skills/.system")
            dirs << default.to_s if default.directory?
          end

          dirs.uniq
        end

        def normalize_skill_catalog_sources(value)
          Array(value).filter_map do |entry|
            next unless entry.is_a?(Hash)

            catalog = entry["catalog"].to_s.strip
            root = entry["root"].to_s.strip
            next if catalog.empty? || root.empty?

            {
              "catalog" => catalog,
              "root" => File.expand_path(root),
            }
          end
        end
        private_class_method :normalize_skill_catalog_sources
      end
    end
  end
end
