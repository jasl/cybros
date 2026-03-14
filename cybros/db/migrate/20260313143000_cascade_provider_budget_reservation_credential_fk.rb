class CascadeProviderBudgetReservationCredentialFk < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :provider_budget_reservations, column: :provider_credential_id
    add_foreign_key :provider_budget_reservations,
      :llm_provider_credentials,
      column: :provider_credential_id,
      on_delete: :cascade
  end
end
