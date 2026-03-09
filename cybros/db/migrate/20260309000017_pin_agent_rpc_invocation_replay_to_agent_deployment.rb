class PinAgentRPCInvocationReplayToAgentDeployment < ActiveRecord::Migration[8.2]
  def change
    remove_index :agent_rpc_invocations, name: "idx_agent_rpc_invocations_replay"

    add_index :agent_rpc_invocations,
      %i[agent_deployment_id binding_fingerprint deployment_activated_at scope_type scope_id method invocation_id],
      unique: true,
      name: "idx_agent_rpc_invocations_replay"
  end
end
