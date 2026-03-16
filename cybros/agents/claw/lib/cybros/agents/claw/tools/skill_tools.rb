require "json"

module Cybros
  module Agents
    module Claw
      module Tools
        class SkillTools
          def initialize(workspace_root:)
            @workspace_root = workspace_root.present? ? Pathname.new(workspace_root) : nil
          end

          def call(logical_tool_name:, arguments:)
            case logical_tool_name.to_s
            when "skills_load", "skills_read_file"
              execute_native_skill_tool(logical_tool_name, arguments)
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
            agent = workspace_agent
            return error_result("skills_catalog_list requires workspace context") unless agent

            entries =
              ::Agents::SkillCatalog.list(agent: agent)
                .select { |entry| catalog_entry_visible?(entry: entry, arguments: arguments) }
                .map { |entry| AgentCore::Utils.deep_stringify_keys(entry) }

            success_result(JSON.generate({ "entries" => entries }))
          rescue AgentCore::ValidationError => e
            error_result(e.message, code: e.code)
          rescue StandardError => e
            error_result("skills_catalog_list failed: #{e.class}: #{e.message}")
          end

          def skills_install(arguments)
            agent = workspace_agent
            return error_result("skills_install requires workspace context") unless agent

            result =
              ::Agents::SkillInstallationService.install(
                agent: agent,
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

            success_result(JSON.generate(::Cybros::AgentOwnedTools.send(:compact_skills_install_result, result)))
          rescue AgentCore::ValidationError => e
            error_result(e.message, code: e.code)
          rescue StandardError => e
            error_result("skills_install failed: #{e.class}: #{e.message}")
          end

          def execute_native_skill_tool(logical_tool_name, arguments)
            agent = workspace_agent
            return error_result("#{logical_tool_name} requires workspace context") unless agent

            store = ::Agents::SkillsStoreBuilder.build(agent: agent)
            registry = AgentCore::Resources::Tools::Registry.new
            registry.register_skills_store(store)

            AgentCore::Utils.deep_stringify_keys(
              registry.execute(name: logical_tool_name.to_s, arguments: arguments || {}).to_h,
            )
          rescue AgentCore::ValidationError => e
            error_result(e.message, code: e.code)
          rescue StandardError => e
            error_result("#{logical_tool_name} failed: #{e.class}: #{e.message}")
          end

          def workspace_agent
            return nil if workspace_root.nil?

            Struct.new(:workspace_root_path, :id).new(workspace_root, nil)
          end

          def catalog_entry_visible?(entry:, arguments:)
            catalog = arguments["catalog"].to_s.strip
            path = arguments["path"].to_s.strip
            query = arguments["query"].to_s.strip

            return false if catalog.present? && entry.fetch(:catalog) != catalog
            return false if path.present? && !entry.fetch(:path).to_s.include?(path)

            if query.present?
              haystack = [entry.fetch(:name), entry.fetch(:description), entry.fetch(:path)].join("\n").downcase
              return false unless haystack.include?(query.downcase)
            end

            true
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
