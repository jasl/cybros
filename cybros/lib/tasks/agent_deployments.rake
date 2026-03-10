require "json"

namespace :agent_deployments do
  desc "Prune orphaned managed deployment runtime config directories"
  task prune_runtime_configs: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", ""))
    root = ENV.fetch("ROOT", "").to_s.strip
    root = nil if root.blank?

    summary = AgentDeployments::RuntimeConfigPruner.new(workspace_root: root, dry_run: dry_run).prune!
    puts JSON.pretty_generate(summary)
  end
end
