module Conversations
  class BranchMemorySnapshot
    def self.snapshot!(parent:, child:)
      parent_workspace = Conversations::WorkspaceInitializer.initialize!(conversation: parent)
      parent_memory_path = Pathname.new(parent_workspace.fetch(:conversation_path)).join("MEMORY.md")
      return { "snapshotted" => false, "reason" => "parent_memory_missing" } unless parent_memory_path.file?

      child_directory = Conversations::WorkspaceInitializer.materialize_conversation_directory!(conversation: child)
      FileUtils.cp(parent_memory_path, child_directory.join("MEMORY.md"))

      {
        "snapshotted" => true,
        "path" => child_directory.join("MEMORY.md").to_s,
      }
    end
  end
end
