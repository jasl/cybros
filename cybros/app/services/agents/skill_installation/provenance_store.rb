require "json"

module Agents
  module SkillInstallation
    class ProvenanceStore
      def initialize(agent:)
        @agent = agent
      end

      def write!(
        skill_name:,
        source_kind:,
        catalog:,
        catalog_entry:,
        repo:,
        ref:,
        path:,
        source_path: nil,
        source_sha256:,
        installed_sha256:,
        snapshot_path:,
        install_mode: nil,
        batch_installed_count: nil,
        batch_install_names: nil
      )
        provenance_path = @agent.workspace_root_path.join(".state", "skills", "#{skill_name}.json")
        FileUtils.mkdir_p(provenance_path.dirname)
        File.write(
          provenance_path,
          JSON.pretty_generate(
            {
              skill_name: skill_name,
              source_kind: source_kind,
              catalog: catalog,
              catalog_entry: catalog_entry,
              repo: repo,
              ref: ref,
              path: path,
              source_path: source_path,
              source_sha256: source_sha256,
              installed_sha256: installed_sha256,
              installed_at: Time.current.utc.iso8601,
              snapshot_path: snapshot_path,
              install_mode: install_mode,
              batch_installed_count: batch_installed_count,
              batch_install_names: Array(batch_install_names).presence,
            }.compact,
          ) + "\n",
          mode: "w",
          encoding: Encoding::UTF_8,
        )
        provenance_path.to_s
      end
    end
  end
end
