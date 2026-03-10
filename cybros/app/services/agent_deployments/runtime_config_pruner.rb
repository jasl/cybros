require "fileutils"
require "set"

module AgentDeployments
  class RuntimeConfigPruner
    def initialize(workspace_root: nil, dry_run: false)
      @workspace_root = workspace_root
      @dry_run = dry_run == true
    end

    def prune!
      root = resolved_workspace_root
      return empty_result(configured_workspace_root: false) if root.nil?

      runtime_root = root.join(".cybros", "agent_deployments")
      return empty_result(configured_workspace_root: true, workspace_root: root) unless runtime_root.directory?

      referenced_ids = referenced_deployment_ids(runtime_root: runtime_root)
      kept = []
      removed = []

      runtime_root.children.sort_by(&:to_s).each do |entry|
        next unless entry.directory?

        deployment_id = entry.basename.to_s
        if referenced_ids.include?(deployment_id)
          kept << deployment_id
          next
        end

        removed << deployment_id
        FileUtils.rm_rf(entry) unless dry_run?
      end

      {
        configured_workspace_root: true,
        workspace_root: root.to_s,
        dry_run: dry_run?,
        scanned_directory_count: kept.length + removed.length,
        kept_deployment_ids: kept.sort,
        removed_deployment_ids: removed.sort,
      }
    end

    private

      attr_reader :workspace_root

      def dry_run?
        @dry_run == true
      end

      def resolved_workspace_root
        explicit_root = workspace_root.to_s.strip
        return normalized_explicit_root(explicit_root) if explicit_root.present?

        RuntimeSetting.instance_agent_workspace_root_path
      rescue RuntimeSetting::InvalidAgentWorkspaceRoot
        nil
      end

      def normalized_explicit_root(value)
        raise ArgumentError, "workspace_root must be an absolute path" unless value.start_with?(File::SEPARATOR)

        Pathname.new(value).cleanpath
      end

      def referenced_deployment_ids(runtime_root:)
        prefix = "#{runtime_root.to_s}#{File::SEPARATOR}"

        AgentDeployment.find_each.each_with_object(Set.new) do |deployment, ids|
          path = deployment.runtime_config_path.to_s
          next if path.blank?

          normalized = Pathname.new(path).cleanpath.to_s
          next unless normalized.start_with?(prefix)

          deployment_id = normalized.delete_prefix(prefix).split(File::SEPARATOR, 2).first.to_s
          ids << deployment_id if deployment_id.present?
        rescue ArgumentError
          next
        end
      end

      def empty_result(configured_workspace_root:, workspace_root: nil)
        {
          configured_workspace_root: configured_workspace_root,
          workspace_root: workspace_root&.to_s,
          dry_run: dry_run?,
          scanned_directory_count: 0,
          kept_deployment_ids: [],
          removed_deployment_ids: [],
        }
      end
  end
end
