class AddRunDraftEntrypointCheckConstraint < ActiveRecord::Migration[8.2]
  def change
    # Run drafts are conversation-scoped; the historical dual-entrypoint check is removed.
  end
end
