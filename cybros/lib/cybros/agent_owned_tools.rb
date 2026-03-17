module Cybros
  module AgentOwnedTools
    module_function

    def build
      [
        read_tool,
        write_tool,
        edit_tool,
        apply_patch_tool,
        glob_tool,
        search_tool,
        exec_tool,
        memory_search_tool,
        memory_get_tool,
        memory_store_tool,
        skills_catalog_list_tool,
        skills_install_tool,
        web_search_tool,
        web_fetch_tool,
      ]
    end

    def read_tool
      tool(
        name: "read",
        description: "Read a UTF-8 text file from the conversation workspace.",
        permission_class: "read",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string" },
          },
          required: ["path"],
          additionalProperties: false,
        },
      )
    end

    def write_tool
      tool(
        name: "write",
        description: "Write or replace a UTF-8 text file inside the conversation workspace.",
        permission_class: "mutate",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string" },
            content: { type: "string" },
          },
          required: ["path", "content"],
          additionalProperties: false,
        },
      )
    end

    def edit_tool
      tool(
        name: "edit",
        description: "Replace one exact text span inside a workspace file.",
        permission_class: "mutate",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string" },
            old_text: { type: "string" },
            new_text: { type: "string" },
          },
          required: ["path", "old_text", "new_text"],
          additionalProperties: false,
        },
      )
    end

    def apply_patch_tool
      tool(
        name: "apply_patch",
        description: "Apply a unified patch against files in the conversation workspace.",
        permission_class: "mutate",
        parameters: {
          type: "object",
          properties: {
            patch: { type: "string" },
          },
          required: ["patch"],
          additionalProperties: false,
        },
      )
    end

    def glob_tool
      tool(
        name: "glob",
        description: "List workspace-relative file paths matching a glob pattern.",
        permission_class: "read",
        parameters: {
          type: "object",
          properties: {
            pattern: { type: "string" },
          },
          required: ["pattern"],
          additionalProperties: false,
        },
      )
    end

    def search_tool
      tool(
        name: "search",
        description: "Search UTF-8 workspace files and return matching paths, lines, and snippets.",
        permission_class: "read",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string" },
          },
          required: ["query"],
          additionalProperties: false,
        },
      )
    end

    def exec_tool
      tool(
        name: "exec",
        description: "Run a non-interactive command in the conversation workspace and capture stdout and stderr.",
        permission_class: "boundary",
        parameters: {
          type: "object",
          properties: {
            command: { type: "string" },
          },
          required: ["command"],
          additionalProperties: false,
        },
        execution_mode: "serial",
      )
    end

    def memory_search_tool
      tool(
        name: "memory_search",
        description: "Search scoped workspace memory files and return matching lines.",
        permission_class: "read",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string" },
            scopes: {
              type: "array",
              items: { type: "string", enum: %w[root conversation lane] },
            },
            target: { type: "string" },
          },
          required: ["query"],
          additionalProperties: false,
        },
      )
    end

    def memory_get_tool
      tool(
        name: "memory_get",
        description: "Read a scoped workspace memory document.",
        permission_class: "read",
        parameters: {
          type: "object",
          properties: {
            scope: { type: "string", enum: %w[root conversation lane] },
            target: { type: "string" },
          },
          additionalProperties: false,
        },
      )
    end

    def memory_store_tool
      tool(
        name: "memory_store",
        description: "Store durable notes in a scoped workspace memory document.",
        permission_class: "mutate",
        parameters: {
          type: "object",
          properties: {
            content: { type: "string" },
            scope: { type: "string", enum: %w[root conversation lane] },
            target: { type: "string" },
            mode: { type: "string", enum: %w[append replace] },
          },
          required: ["content"],
          additionalProperties: false,
        },
      )
    end

    def web_search_tool
      tool(
        name: "web_search",
        description: "Search the web and return structured results.",
        permission_class: "read",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string" },
            count: { type: "integer", minimum: 1, maximum: 10 },
          },
          required: ["query"],
          additionalProperties: false,
        },
      )
    end

    def skills_catalog_list_tool
      tool(
        name: "skills_catalog_list",
        description: "List installable skills from configured catalogs.",
        permission_class: "read",
        parameters: {
          type: "object",
          properties: {
            catalog: { type: "string" },
            path: { type: "string" },
            query: { type: "string" },
          },
          additionalProperties: false,
        },
      ) do |arguments, context:|
        agent = agent_from_context(context)
        return AgentCore::Resources::Tools::ToolResult.error(text: "skills_catalog_list requires an agent context") unless agent

        entries =
          ::Agents::SkillCatalog.list(agent: agent)
            .select { |entry| catalog_entry_visible?(entry: entry, arguments: arguments) }
            .map { |entry| AgentCore::Utils.deep_stringify_keys(entry) }

        AgentCore::Resources::Tools::ToolResult.success(
          text: JSON.generate({ "entries" => entries }),
        )
      end
    end

    def skills_install_tool
      tool(
        name: "skills_install",
        description: "Install or replace agent-local skills from a catalog entry, GitHub skill path, or GitHub repo root batch.",
        permission_class: "mutate",
        parameters: {
          type: "object",
          properties: {
            source_kind: { type: "string", enum: %w[catalog github] },
            catalog: { type: "string" },
            catalog_entry: { type: "string" },
            repo: { type: "string" },
            ref: { type: "string" },
            path: { type: "string" },
            install_as: { type: "string" },
            replace: { type: "boolean" },
            expected_sha256: { type: "string" },
          },
          required: ["source_kind"],
          additionalProperties: false,
        },
        approval_preview: method(:skills_install_approval_preview),
      ) do |arguments, context:|
        agent = agent_from_context(context)
        return AgentCore::Resources::Tools::ToolResult.error(text: "skills_install requires an agent context") unless agent

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

        AgentCore::Resources::Tools::ToolResult.success(
          text: JSON.generate(compact_skills_install_result(result)),
        )
      end
    end

    def skills_install_approval_preview(arguments:, context:)
      agent = agent_from_context(context)
      return nil unless agent

      prepared =
        ::Agents::SkillInstallationService.prepare(
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

      candidates =
        if prepared.fetch(:mode) == "repo_root_batch"
          prepared.fetch(:candidates).map { |candidate| skills_install_preview_candidate(candidate) }
        else
          [
            {
              "install_name" => prepared.fetch(:install_name),
              "source_path" => prepared[:path].presence || prepared.fetch(:install_name),
              "replace" => prepared.fetch(:replace),
              "file_count" => prepared.fetch(:manifest).fetch(:files).length,
              "source_sha256" => prepared.fetch(:source_sha256),
            },
          ]
        end

      {
        "mode" => prepared.fetch(:mode),
        "source_kind" => prepared.fetch(:source_kind),
        "repo" => prepared[:repo],
        "ref" => prepared[:ref],
        "candidate_count" => candidates.length,
        "candidates" => candidates,
      }.compact
    end
    private_class_method :skills_install_approval_preview

    def skills_install_preview_candidate(candidate)
      {
        "install_name" => candidate.fetch(:install_name),
        "source_path" => candidate.fetch(:source_path),
        "replace" => candidate.fetch(:replace),
        "file_count" => candidate.fetch(:manifest).fetch(:files).length,
        "source_sha256" => candidate.fetch(:source_sha256),
      }
    end
    private_class_method :skills_install_preview_candidate

    def compact_skills_install_result(result)
      payload = AgentCore::Utils.deep_stringify_keys(result)
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
    private_class_method :compact_skills_install_result

    def web_fetch_tool
      tool(
        name: "web_fetch",
        description: "Fetch a web page and return extracted text content.",
        permission_class: "read",
        parameters: {
          type: "object",
          properties: {
            url: { type: "string" },
            max_chars: { type: "integer", minimum: 100, maximum: 8000 },
          },
          required: ["url"],
          additionalProperties: false,
        },
      )
    end

    def agent_from_context(context)
      return nil unless context.respond_to?(:attributes)

      raw_attributes = context.attributes
      return nil unless raw_attributes.is_a?(Hash)

      attributes = AgentCore::Utils.deep_stringify_keys(raw_attributes)
      agent_id = attributes.dig("agent", "id").to_s.strip.presence
      return Agent.find_by(id: agent_id) if agent_id.present?

      conversation_id =
        attributes.dig("cybros", "session_context", "conversation_id").to_s.strip.presence ||
          attributes.dig("cybros", "execution_context", "conversation_id").to_s.strip.presence
      return nil unless conversation_id

      Conversation.find_by(id: conversation_id)&.agent
    end
    private_class_method :agent_from_context

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
    private_class_method :catalog_entry_visible?

    def tool(name:, description:, permission_class:, parameters:, execution_mode: "serial", approval_preview: nil, &implementation)
      implementation ||= lambda do |_arguments, context:|
        _ = context
        AgentCore::Resources::Tools::ToolResult.error(
          text: "#{name} must be routed to the agent-owned execution surface",
        )
      end

      metadata = {
        source: :agent_owned,
        permission_class: permission_class,
        execution_mode: execution_mode,
      }
      metadata[:approval_preview] = approval_preview if approval_preview

      AgentCore::Resources::Tools::Tool.new(
        name: name,
        description: description,
        parameters: parameters,
        metadata: metadata,
        &implementation
      )
    end
    private_class_method :tool
  end
end
