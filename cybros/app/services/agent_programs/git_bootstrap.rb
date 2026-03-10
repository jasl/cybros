require "open3"

module AgentPrograms
  class GitBootstrap
    IMPORT_COMMIT_MESSAGE = "Import bundled default agent".freeze

    def self.bootstrap!(source_root:, import_tag:)
      new(source_root: source_root, import_tag: import_tag).bootstrap!
    end

    def initialize(source_root:, import_tag:)
      @source_root = Pathname.new(source_root.to_s)
      @import_tag = import_tag.to_s
    end

    def bootstrap!
      run!("git", "init", "-b", "main")
      run!("git", "add", ".")
      run!(
        "git",
        "-c",
        "user.name=Cybros",
        "-c",
        "user.email=cybros@example.invalid",
        "commit",
        "-m",
        IMPORT_COMMIT_MESSAGE,
      )
      run!("git", "tag", import_tag) if import_tag.present?
      source_root
    end

    private

      attr_reader :source_root, :import_tag

      def run!(*command)
        stdout, stderr, status = Open3.capture3(*command, chdir: source_root.to_s)
        return stdout if status.success?

        raise "git bootstrap failed: #{stderr.presence || stdout}".strip
      end
  end
end
