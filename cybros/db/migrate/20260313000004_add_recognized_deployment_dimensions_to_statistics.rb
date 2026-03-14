class AddRecognizedDeploymentDimensionsToStatistics < ActiveRecord::Migration[8.0]
  def change
    add_reference :statistics_tool_call_facts,
      :recognized_deployment,
      type: :uuid,
      null: true,
      foreign_key: { to_table: :recognized_deployments, on_delete: :nullify }
    add_column :statistics_tool_call_facts, :recognized_deployment_key, :string

    add_index :statistics_tool_call_facts,
      [:sample_origin, :recognized_deployment_key],
      name: "idx_tool_call_facts_sample_origin_recognized_deployment"
  end
end
