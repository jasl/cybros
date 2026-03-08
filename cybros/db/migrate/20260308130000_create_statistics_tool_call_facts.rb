class CreateStatisticsToolCallFacts < ActiveRecord::Migration[8.2]
  def change
    create_table :statistics_tool_call_facts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :task_node_id, null: false
      t.uuid :retry_of_task_node_id
      t.uuid :conversation_id, null: false
      t.uuid :root_conversation_id, null: false
      t.uuid :user_id
      t.uuid :graph_id, null: false
      t.uuid :turn_id, null: false

      t.string :sample_origin, null: false
      t.string :execution_scope, null: false
      t.string :tool_call_id
      t.string :requested_name
      t.string :resolved_name
      t.string :name_resolution
      t.string :arguments_resolution
      t.string :model_attempt_class, null: false
      t.string :source
      t.string :provider_key
      t.string :model_ref

      t.string :execution_readiness, null: false
      t.boolean :entered_execution, null: false, default: false
      t.string :tool_outcome, null: false
      t.string :failure_class
      t.string :failure_code
      t.boolean :retryable
      t.boolean :manual_retry, null: false, default: false

      t.datetime :started_at
      t.datetime :finished_at
      t.date :effective_on
      t.integer :duration_ms

      t.timestamps
    end

    add_index :statistics_tool_call_facts, :task_node_id, unique: true
    add_index :statistics_tool_call_facts, %i[sample_origin effective_on]
    add_index :statistics_tool_call_facts, %i[sample_origin user_id]
    add_index :statistics_tool_call_facts, %i[sample_origin model_ref]
    add_index :statistics_tool_call_facts, %i[sample_origin resolved_name]
    add_index :statistics_tool_call_facts, %i[sample_origin execution_scope]
    add_index :statistics_tool_call_facts, %i[sample_origin started_at]
    add_index :statistics_tool_call_facts, %i[sample_origin finished_at]

    add_check_constraint :statistics_tool_call_facts,
                         "sample_origin::text = ANY (ARRAY['runtime'::character varying::text, 'eval'::character varying::text, 'debug'::character varying::text, 'replay'::character varying::text])",
                         name: "check_statistics_tool_call_facts_sample_origin_enum"
    add_check_constraint :statistics_tool_call_facts,
                         "execution_scope::text = ANY (ARRAY['parent'::character varying::text, 'subagent_child'::character varying::text])",
                         name: "check_statistics_tool_call_facts_execution_scope_enum"
    add_check_constraint :statistics_tool_call_facts,
                         "model_attempt_class::text = ANY (ARRAY['first_pass'::character varying::text, 'repaired_name'::character varying::text, 'repaired_args'::character varying::text, 'repaired_both'::character varying::text])",
                         name: "check_statistics_tool_call_facts_model_attempt_class_enum"
    add_check_constraint :statistics_tool_call_facts,
                         "execution_readiness::text = ANY (ARRAY['executable'::character varying::text, 'invalid_args'::character varying::text, 'tool_not_found'::character varying::text, 'policy_denied'::character varying::text, 'awaiting_approval'::character varying::text, 'approval_rejected'::character varying::text])",
                         name: "check_statistics_tool_call_facts_execution_readiness_enum"
    add_check_constraint :statistics_tool_call_facts,
                         "tool_outcome::text = ANY (ARRAY['success'::character varying::text, 'failed'::character varying::text, 'not_executed'::character varying::text])",
                         name: "check_statistics_tool_call_facts_tool_outcome_enum"
    add_check_constraint :statistics_tool_call_facts,
                         "failure_class IS NULL OR failure_class::text = ANY (ARRAY['validation_error'::character varying::text, 'implementation_error'::character varying::text, 'remote_api_error'::character varying::text, 'timeout'::character varying::text, 'rate_limit'::character varying::text, 'auth'::character varying::text, 'unknown'::character varying::text])",
                         name: "check_statistics_tool_call_facts_failure_class_enum"
    add_check_constraint :statistics_tool_call_facts,
                         "duration_ms IS NULL OR duration_ms >= 0",
                         name: "check_statistics_tool_call_facts_duration_ms_non_negative"
  end
end
