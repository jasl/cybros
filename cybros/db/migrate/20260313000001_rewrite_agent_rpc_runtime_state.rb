class RewriteAgentRPCRuntimeState < ActiveRecord::Migration[8.1]
  class AgentRPCInvocation < ApplicationRecord
    self.table_name = "agent_rpc_invocations"
  end

  class AgentRPCSession < ApplicationRecord
    self.table_name = "agent_rpc_sessions"
  end

  class AgentRPCOperationReceipt < ApplicationRecord
    self.table_name = "agent_rpc_operation_receipts"
  end

  def up
    clear_ephemeral_runtime_state!

    add_reference :agent_rpc_invocations, :agent, type: :uuid, foreign_key: true
    add_reference :agent_rpc_invocations, :recognized_deployment, type: :uuid, foreign_key: true
    add_column :agent_rpc_invocations, :recognized_deployment_key, :string

    add_reference :agent_rpc_sessions, :agent, type: :uuid, foreign_key: true
    add_reference :agent_rpc_sessions, :recognized_deployment, type: :uuid, foreign_key: true
    add_column :agent_rpc_sessions, :recognized_deployment_key, :string

    change_column_null :agent_rpc_invocations, :agent_id, false
    change_column_null :agent_rpc_invocations, :recognized_deployment_id, false
    change_column_null :agent_rpc_invocations, :recognized_deployment_key, false
    change_column_null :agent_rpc_sessions, :agent_id, false
    change_column_null :agent_rpc_sessions, :recognized_deployment_id, false
    change_column_null :agent_rpc_sessions, :recognized_deployment_key, false

    remove_foreign_key :agent_rpc_sessions, name: "fk_agent_rpc_sessions_invocation_deploy"
    remove_foreign_key :agent_rpc_invocations, column: :agent_deployment_id
    remove_foreign_key :agent_rpc_sessions, column: :agent_deployment_id
    remove_foreign_key :agent_rpc_sessions, column: :agent_program_id

    remove_index :agent_rpc_invocations, name: "idx_agent_rpc_invocations_replay"
    remove_index :agent_rpc_invocations, name: "index_agent_rpc_invocations_on_agent_deployment_id"
    remove_index :agent_rpc_invocations, name: "idx_agent_rpc_invocations_id_deploy"
    remove_index :agent_rpc_sessions, name: "index_agent_rpc_sessions_on_agent_deployment_id"
    remove_index :agent_rpc_sessions, name: "index_agent_rpc_sessions_on_agent_program_id"
    remove_index :agent_rpc_sessions, name: "idx_agent_rpc_sessions_invocation_deploy"

    remove_column :agent_rpc_invocations, :agent_deployment_id
    remove_column :agent_rpc_sessions, :agent_deployment_id
    remove_column :agent_rpc_sessions, :agent_program_id

    add_index :agent_rpc_invocations, :recognized_deployment_key
    add_index :agent_rpc_invocations,
      [:agent_id, :recognized_deployment_key, :deployment_activated_at, :scope_type, :scope_id, :method, :invocation_id],
      unique: true,
      name: "idx_agent_rpc_invocations_replay"
    add_index :agent_rpc_invocations, [:id, :recognized_deployment_id], unique: true, name: "idx_agent_rpc_invocations_id_recognized"

    add_index :agent_rpc_sessions, :recognized_deployment_key
    add_index :agent_rpc_sessions, [:agent_rpc_invocation_id, :recognized_deployment_id], name: "idx_agent_rpc_sessions_invocation_recognized"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "agent rpc runtime state cutover is destructive"
  end

  private

    def clear_ephemeral_runtime_state!
      AgentRPCInvocation.update_all(last_session_id: nil)
      AgentRPCSession.update_all(agent_rpc_invocation_id: nil)
      AgentRPCOperationReceipt.delete_all
      AgentRPCSession.delete_all
      AgentRPCInvocation.delete_all
    end
end
