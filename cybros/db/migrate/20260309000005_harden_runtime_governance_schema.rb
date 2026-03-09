class HardenRuntimeGovernanceSchema < ActiveRecord::Migration[8.2]
  PROVIDER_BACKOFF_POLICY = {
    kind: "exponential",
    base_delay_ms: 500,
    max_delay_ms: 30000,
  }.freeze

  def up
    change_column_default :llm_provider_credentials, :max_concurrent_requests, 4
    change_column_default :llm_provider_credentials, :requests_per_minute, 120
    change_column_default :llm_provider_credentials, :tokens_per_minute, 240000
    change_column_default :llm_provider_credentials, :burst_limit, 8
    change_column_default :llm_provider_credentials, :backoff_policy, PROVIDER_BACKOFF_POLICY

    execute <<~SQL
      UPDATE llm_provider_credentials
      SET max_concurrent_requests = 4
      WHERE max_concurrent_requests IS NULL
    SQL

    execute <<~SQL
      UPDATE llm_provider_credentials
      SET requests_per_minute = 120
      WHERE requests_per_minute IS NULL
    SQL

    execute <<~SQL
      UPDATE llm_provider_credentials
      SET tokens_per_minute = 240000
      WHERE tokens_per_minute IS NULL
    SQL

    execute <<~SQL
      UPDATE llm_provider_credentials
      SET burst_limit = 8
      WHERE burst_limit IS NULL
    SQL

    execute <<~SQL
      UPDATE llm_provider_credentials
      SET backoff_policy = jsonb_set(COALESCE(backoff_policy, '{}'::jsonb), '{max_delay_ms}', '30000'::jsonb, true)
      WHERE backoff_policy IS NULL OR backoff_policy->>'max_delay_ms' IS NULL
    SQL

    change_column_null :llm_provider_credentials, :max_concurrent_requests, false
    change_column_null :llm_provider_credentials, :requests_per_minute, false
    change_column_null :llm_provider_credentials, :tokens_per_minute, false
    change_column_null :llm_provider_credentials, :burst_limit, false

    unless index_exists?(:workspaces, %i[id execution_location_id], name: "index_workspaces_on_id_and_execution_location_id")
      add_index :workspaces, %i[id execution_location_id],
                unique: true,
                name: "index_workspaces_on_id_and_execution_location_id"
    end

    unless index_exists?(:execution_targets, %i[workspace_id execution_location_id], name: "idx_execution_targets_on_workspace_location")
      add_index :execution_targets, %i[workspace_id execution_location_id],
                unique: true,
                name: "idx_execution_targets_on_workspace_location"
    end

    unless index_exists?(:execution_targets, %i[execution_location_id workspace_id], name: "idx_execution_targets_on_location_workspace")
      add_index :execution_targets, %i[execution_location_id workspace_id],
                unique: true,
                name: "idx_execution_targets_on_location_workspace"
    end

    unless foreign_key_exists?(:execution_targets, :workspaces, column: %i[workspace_id execution_location_id], name: "fk_execution_targets_workspace_location")
      execute <<~SQL
        ALTER TABLE execution_targets
        ADD CONSTRAINT fk_execution_targets_workspace_location
        FOREIGN KEY (workspace_id, execution_location_id)
        REFERENCES workspaces (id, execution_location_id)
      SQL
    end
  end

  def down
    execute <<~SQL
      ALTER TABLE execution_targets
      DROP CONSTRAINT IF EXISTS fk_execution_targets_workspace_location
    SQL

    remove_index :execution_targets, name: "idx_execution_targets_on_location_workspace" if index_exists?(:execution_targets, %i[execution_location_id workspace_id], name: "idx_execution_targets_on_location_workspace")
    remove_index :execution_targets, name: "idx_execution_targets_on_workspace_location" if index_exists?(:execution_targets, %i[workspace_id execution_location_id], name: "idx_execution_targets_on_workspace_location")
    remove_index :workspaces, name: "index_workspaces_on_id_and_execution_location_id" if index_exists?(:workspaces, %i[id execution_location_id], name: "index_workspaces_on_id_and_execution_location_id")

    change_column_null :llm_provider_credentials, :burst_limit, true
    change_column_null :llm_provider_credentials, :tokens_per_minute, true
    change_column_null :llm_provider_credentials, :requests_per_minute, true
    change_column_null :llm_provider_credentials, :max_concurrent_requests, true

    change_column_default :llm_provider_credentials, :backoff_policy, { kind: "exponential", base_delay_ms: 500 }
    change_column_default :llm_provider_credentials, :burst_limit, nil
    change_column_default :llm_provider_credentials, :tokens_per_minute, nil
    change_column_default :llm_provider_credentials, :requests_per_minute, nil
    change_column_default :llm_provider_credentials, :max_concurrent_requests, nil
  end
end
