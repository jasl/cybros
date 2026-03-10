class BackfillLegacyBuiltinConversations < ActiveRecord::Migration[8.0]
  def up
    say_with_time "backfilling legacy conversations onto the bundled default agent" do
      default_program = AgentPrograms::Creator.create_from_profile!(name: "Default", profile_source: "default-assistant")

      execute <<~SQL.squish
        UPDATE conversations
           SET agent_program_id = #{quote(default_program.id)},
               agent_config_schema_fingerprint = COALESCE(agent_config_schema_fingerprint, #{quote(default_program.config_schema_fingerprint)}),
               updated_at = CURRENT_TIMESTAMP
         WHERE agent_program_id IS NULL
      SQL
    end

    change_column_null :conversations, :agent_program_id, false
  end

  def down
    change_column_null :conversations, :agent_program_id, true
  end
end
