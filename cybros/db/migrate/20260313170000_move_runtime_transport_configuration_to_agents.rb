class MoveRuntimeTransportConfigurationToAgents < ActiveRecord::Migration[8.1]
  def up
    add_column :agents, :transport_kind, :string
    add_column :agents, :endpoint_url, :string
    add_column :agents, :deployment_bearer_secret_ref, :string
    add_column :agents, :deployment_fingerprint, :string
    add_column :agents, :status, :string, null: false, default: "inactive"
    add_column :agents, :health_status, :string, null: false, default: "unknown"
    add_column :agents, :protocol_version, :string
    add_column :agents, :agent_sdk_version, :string
    add_column :agents, :supported_methods, :text, array: true, null: false, default: []
    add_column :agents, :capability_snapshot, :jsonb, null: false, default: {}
    add_column :agents, :inspection_details, :jsonb, null: false, default: {}
    add_column :agents, :transport_config, :jsonb, null: false, default: {}
    add_column :agents, :activated_at, :datetime
    add_column :agents, :deactivated_at, :datetime
    add_column :agents, :last_health_checked_at, :datetime
    add_column :agents, :last_inspected_at, :datetime

    say_with_time "Backfill agent runtime transport configuration from legacy deployments" do
      execute <<~SQL
        WITH ranked_deployments AS (
          SELECT
            agents.id AS agent_id,
            agent_deployments.transport_kind,
            agent_deployments.endpoint_url,
            agent_deployments.deployment_bearer_secret_ref,
            agent_deployments.deployment_fingerprint,
            agent_deployments.status,
            agent_deployments.health_status,
            agent_deployments.protocol_version,
            agent_deployments.agent_sdk_version,
            agent_deployments.supported_methods,
            agent_deployments.capability_snapshot,
            agent_deployments.inspection_details,
            agent_deployments.transport_config,
            agent_deployments.activated_at,
            agent_deployments.deactivated_at,
            agent_deployments.last_health_checked_at,
            agent_deployments.last_inspected_at,
            ROW_NUMBER() OVER (
              PARTITION BY agents.id
              ORDER BY
                CASE WHEN agent_deployments.status = 'active' THEN 0 ELSE 1 END,
                CASE WHEN agent_deployments.health_status = 'healthy' THEN 0 ELSE 1 END,
                agent_deployments.activated_at DESC NULLS LAST,
                agent_deployments.updated_at DESC NULLS LAST,
                agent_deployments.created_at DESC NULLS LAST,
                agent_deployments.id DESC
            ) AS row_number
          FROM agents
          INNER JOIN agent_deployments
            ON agent_deployments.agent_program_id = agents.legacy_agent_program_id
        )
        UPDATE agents
        SET
          transport_kind = ranked_deployments.transport_kind,
          endpoint_url = ranked_deployments.endpoint_url,
          deployment_bearer_secret_ref = ranked_deployments.deployment_bearer_secret_ref,
          deployment_fingerprint = ranked_deployments.deployment_fingerprint,
          status = ranked_deployments.status,
          health_status = ranked_deployments.health_status,
          protocol_version = ranked_deployments.protocol_version,
          agent_sdk_version = ranked_deployments.agent_sdk_version,
          supported_methods = ranked_deployments.supported_methods,
          capability_snapshot = ranked_deployments.capability_snapshot,
          inspection_details = ranked_deployments.inspection_details,
          transport_config = ranked_deployments.transport_config,
          activated_at = ranked_deployments.activated_at,
          deactivated_at = ranked_deployments.deactivated_at,
          last_health_checked_at = ranked_deployments.last_health_checked_at,
          last_inspected_at = ranked_deployments.last_inspected_at
        FROM ranked_deployments
        WHERE ranked_deployments.agent_id = agents.id
          AND ranked_deployments.row_number = 1
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "agent runtime transport cutover is destructive"
  end
end
