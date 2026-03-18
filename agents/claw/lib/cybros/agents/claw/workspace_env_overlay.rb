require "pathname"

module Cybros
  module Agents
    module Claw
      class WorkspaceEnvOverlay
        SEARCH_FILENAMES = [".env", ".env.agent"].freeze
        KEY_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

        ParseError = Class.new(StandardError)

        def self.load(process_env:, root_path:, lane_path:)
          new(process_env:, root_path:, lane_path:).load
        end

        def initialize(process_env:, root_path:, lane_path:)
          @env = normalize_env(process_env)
          @root_path = path_or_nil(root_path)
          @lane_path = path_or_nil(lane_path)
        end

        def load
          loaded_files = []
          ignored_files = []
          warnings = []

          candidate_paths.each do |path|
            next unless path.file?

            begin
              apply_file(path)
              loaded_files << path.to_s
            rescue ParseError => e
              ignored_files << path.to_s
              warnings << { file: path.to_s, message: "invalid env file: #{e.message}" }
            end
          end

          {
            env: @env,
            loaded_files: loaded_files,
            ignored_files: ignored_files,
            warnings: warnings,
          }
        end

        private

          def candidate_paths
            [@root_path, @lane_path].compact.flat_map do |scope_path|
              SEARCH_FILENAMES.map { |filename| scope_path.join(filename) }
            end.uniq
          end

          def apply_file(path)
            path.read.each_line.with_index(1) do |line, line_number|
              apply_line(line, line_number:)
            end
          end

          def apply_line(line, line_number:)
            stripped = line.to_s.strip
            return if stripped.empty? || stripped.start_with?("#")

            if stripped.start_with?("unset ")
              key = stripped.delete_prefix("unset ").strip
              validate_key!(key, line_number:)
              @env.delete(key)
              return
            end

            assignment = stripped.start_with?("export ") ? stripped.delete_prefix("export ").strip : stripped
            key, raw_value = assignment.split("=", 2)
            raise ParseError, "line #{line_number} must contain KEY=VALUE" if raw_value.nil?

            key = key.to_s.strip
            validate_key!(key, line_number:)
            @env[key] = parse_value(raw_value)
          end

          def validate_key!(key, line_number:)
            raise ParseError, "line #{line_number} has invalid key" unless KEY_PATTERN.match?(key)
          end

          def parse_value(raw_value)
            value = raw_value.to_s.strip
            return value[1...-1].gsub("\\\"", "\"").gsub("\\\\", "\\").gsub("\\n", "\n").gsub("\\t", "\t") if quoted?(value, "\"")
            return value[1...-1] if quoted?(value, "'")

            value
          end

          def quoted?(value, quote)
            value.start_with?(quote) && value.end_with?(quote) && value.length >= 2
          end

          def normalize_env(process_env)
            process_env.to_h.each_with_object({}) do |(key, value), memo|
              memo[key.to_s] = value.to_s
            end
          end

          def path_or_nil(value)
            raw = value.to_s.strip
            return nil if raw.empty?

            Pathname.new(raw)
          end
      end
    end
  end
end
