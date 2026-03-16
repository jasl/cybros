require "json"

module Cybros
  module Agents
    module Claw
      module Tools
        class SkillTools
          DEFAULT_MAX_BODY_BYTES = 200_000
          DEFAULT_MAX_FILE_BYTES = 200_000

          def initialize(workspace_root:)
            @workspace_root = workspace_root.present? ? Pathname.new(workspace_root) : nil
          end

          def call(logical_tool_name:, arguments:)
            case logical_tool_name.to_s
            when "skills_load"
              skills_load(arguments)
            when "skills_read_file"
              skills_read_file(arguments)
            when "skills_catalog_list"
              skills_catalog_list(arguments)
            when "skills_install"
              skills_install(arguments)
            else
              nil
            end
          end

          private

          attr_reader :workspace_root

          def skills_catalog_list(arguments)
            entries =
              SkillCatalog.list(workspace_root: workspace_root)
                .select { |entry| catalog_entry_visible?(entry: entry, arguments: arguments) }

            success_result(JSON.generate({ "entries" => entries }))
          rescue ValidationError => e
            error_result(e.message, code: e.code)
          rescue StandardError => e
            error_result("skills_catalog_list failed: #{e.class}: #{e.message}")
          end

          def skills_install(arguments)
            result =
              SkillInstallationService.install(
                workspace_root: workspace_root,
                source_kind: arguments["source_kind"],
                catalog: arguments["catalog"],
                catalog_entry: arguments["catalog_entry"],
                repo: arguments["repo"],
                ref: arguments["ref"],
                path: arguments["path"],
                install_as: arguments["install_as"],
                replace: ActiveModel::Type::Boolean.new.cast(arguments["replace"]),
                expected_sha256: arguments["expected_sha256"],
              )

            success_result(JSON.generate(compact_skills_install_result(result)))
          rescue ValidationError => e
            error_result(e.message, code: e.code)
          rescue StandardError => e
            error_result("skills_install failed: #{e.class}: #{e.message}")
          end

          def skills_load(arguments)
            name = arguments.fetch("name").to_s
            skill = installed_skills_store.load_skill(name:, max_bytes: DEFAULT_MAX_BODY_BYTES)

            success_result(
              JSON.generate(
                {
                  "meta" => {
                    "name" => skill.meta.name,
                    "description" => skill.meta.description,
                    "metadata" => skill.meta.metadata,
                  }.compact,
                  "body_markdown" => skill.body_markdown,
                  "body_truncated" => skill.body_truncated,
                  "files_index" => skill.files_index,
                },
              ),
            )
          rescue KeyError => e
            error_result("skills_load missing argument: #{e.message}")
          rescue ValidationError => e
            error_result(e.message, code: e.code)
          rescue StandardError => e
            error_result("skills_load failed: #{e.class}: #{e.message}")
          end

          def skills_read_file(arguments)
            name = arguments.fetch("name").to_s
            rel_path = arguments.fetch("rel_path").to_s
            bytes = installed_skills_store.read_skill_file_bytes(name:, rel_path:, max_bytes: DEFAULT_MAX_FILE_BYTES)

            if SkillsStore.text_bytes?(bytes)
              success_result(bytes.dup.force_encoding(Encoding::UTF_8))
            else
              {
                "content" => [SkillsStore.binary_content_block(bytes:, rel_path:)],
                "error" => false,
                "metadata" => {
                  "bytes" => bytes.bytesize,
                  "media_type" => SkillsStore.mime_type_for(rel_path),
                  "filename" => File.basename(rel_path),
                },
              }
            end
          rescue KeyError => e
            error_result("skills_read_file missing argument: #{e.message}")
          rescue ValidationError => e
            error_result(e.message, code: e.code)
          rescue StandardError => e
            error_result("skills_read_file failed: #{e.class}: #{e.message}")
          end

          def installed_skills_store
            dirs = platform_skill_dirs
            workspace_skills_dir = workspace_root.join("skills")
            dirs << workspace_skills_dir.to_s if workspace_skills_dir.directory?
            SkillsStore.new(dirs:, strict: true)
          end

          def catalog_entry_visible?(entry:, arguments:)
            catalog = arguments["catalog"].to_s.strip
            path = arguments["path"].to_s.strip
            query = arguments["query"].to_s.strip

            return false if catalog.present? && entry.fetch("catalog") != catalog
            return false if path.present? && !entry.fetch("path").to_s.include?(path)

            if query.present?
              haystack = [entry.fetch("name"), entry.fetch("description"), entry.fetch("path")].join("\n").downcase
              return false unless haystack.include?(query.downcase)
            end

            true
          end

          def platform_skill_dirs
            RuntimeSettings.platform_skill_dirs
          end

          def compact_skills_install_result(result)
            payload = Manifest.deep_stringify(result)
            payload["installed_skills"] =
              Array(payload["installed_skills"]).map do |entry|
                compacted = {
                  "installed_name" => entry.fetch("installed_name"),
                  "source_path" => entry.fetch("source_path"),
                  "source_sha256" => entry.fetch("source_sha256"),
                  "installed_sha256" => entry.fetch("installed_sha256"),
                }
                compacted["snapshot_path"] = entry["snapshot_path"] if entry["snapshot_path"].present?
                compacted
              end
            payload
          end

          def success_result(text)
            {
              "content" => [{ "type" => "text", "text" => text.to_s }],
              "error" => false,
              "metadata" => {},
            }
          end

          def error_result(text, code: nil)
            {
              "content" => [{ "type" => "text", "text" => text.to_s }],
              "error" => true,
              "metadata" => code.present? ? { "code" => code.to_s } : {},
            }
          end
        end
      end
    end
  end
end
