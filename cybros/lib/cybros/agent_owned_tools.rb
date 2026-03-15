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
        description: "Search the conversation-owned memory document and return matching lines.",
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

    def memory_get_tool
      tool(
        name: "memory_get",
        description: "Read the current conversation-owned memory document.",
        permission_class: "read",
        parameters: {
          type: "object",
          properties: {},
          additionalProperties: false,
        },
      )
    end

    def memory_store_tool
      tool(
        name: "memory_store",
        description: "Store durable notes in the conversation-owned memory document.",
        permission_class: "mutate",
        parameters: {
          type: "object",
          properties: {
            content: { type: "string" },
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

    def tool(name:, description:, permission_class:, parameters:, execution_mode: "serial")
      AgentCore::Resources::Tools::Tool.new(
        name: name,
        description: description,
        parameters: parameters,
        metadata: {
          source: :agent_owned,
          permission_class: permission_class,
          execution_mode: execution_mode,
        },
      ) do |_arguments, context:|
        _ = context
        AgentCore::Resources::Tools::ToolResult.error(
          text: "#{name} must be routed to the agent-owned execution surface",
        )
      end
    end
    private_class_method :tool
  end
end
