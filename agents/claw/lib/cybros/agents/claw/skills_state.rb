require "fileutils"

module Cybros
  module Agents
    module Claw
      module SkillsState
        module_function

        def dirty_marker_path_for(workspace_root:)
          Pathname.new(workspace_root).join(".state", "skills", "inventory-dirty")
        end

        def mark_dirty!(workspace_root:)
          path = dirty_marker_path_for(workspace_root:)
          FileUtils.mkdir_p(path.dirname)
          File.write(path, Time.current.utc.iso8601 + "\n", mode: "w", encoding: Encoding::UTF_8)
          path
        end
      end
    end
  end
end
