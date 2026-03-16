module Agents
  module BundledSources
    SOURCE_DIRECTORIES = {
      "claw" => "claw",
    }.freeze

    module_function

    def available_keys
      SOURCE_DIRECTORIES.keys.sort
    end

    def path_for(key)
      relative_directory = SOURCE_DIRECTORIES[key.to_s]
      return nil if relative_directory.nil?

      root_path.join(relative_directory).cleanpath
    end

    def relative_path_for(key)
      path = path_for(key)
      return nil if path.nil?

      path.relative_path_from(Rails.root).to_s
    rescue ArgumentError
      nil
    end

    def root_path
      Rails.root.parent.join("agents").expand_path
    end
  end
end
