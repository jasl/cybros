class UpdateStatisticsToolCallFactExecutionScopeEnum < ActiveRecord::Migration[8.2]
  CONSTRAINT_NAME = "check_statistics_tool_call_facts_execution_scope_enum"
  OLD_EXPRESSION = "execution_scope::text = ANY (ARRAY['parent'::character varying::text, 'subagent_child'::character varying::text])"
  NEW_EXPRESSION = "execution_scope::text = ANY (ARRAY['parent'::character varying::text, 'subagent'::character varying::text])"

  def up
    remove_check_constraint :statistics_tool_call_facts, name: CONSTRAINT_NAME
    add_check_constraint :statistics_tool_call_facts, NEW_EXPRESSION, name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :statistics_tool_call_facts, name: CONSTRAINT_NAME
    add_check_constraint :statistics_tool_call_facts, OLD_EXPRESSION, name: CONSTRAINT_NAME
  end
end
