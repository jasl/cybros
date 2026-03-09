class AddRunDraftEntrypointCheckConstraint < ActiveRecord::Migration[8.2]
  def change
    add_check_constraint :run_drafts,
      "num_nonnulls(conversation_id, automation_id) = 1",
      name: "chk_run_drafts_one_entrypoint"
  end
end
