module Conduits
  class Facility < ApplicationRecord
    self.table_name = "conduits_facilities"

    class LockConflict < StandardError; end

    belongs_to :account, optional: true
    belongs_to :owner,     class_name: "User", inverse_of: :facilities
    belongs_to :territory, class_name: "Conduits::Territory", inverse_of: :facilities

    belongs_to :locked_by_directive, class_name: "Conduits::Directive",
               foreign_key: :locked_by_directive_id, optional: true

    has_many :directives, class_name: "Conduits::Directive",
             foreign_key: :facility_id, inverse_of: :facility, dependent: :restrict_with_error

    validates :kind, presence: true,
              inclusion: { in: %w[repo empty imported_path] }
    validates :retention_policy, presence: true

    def locked?
      locked_by_directive_id.present?
    end

    # Atomically locks the facility for the given directive.
    # Returns true if lock was acquired, false if already locked by another directive.
    # Uses WHERE locked_by_directive_id IS NULL to prevent race conditions.
    def lock!(directive)
      return true if locked_by_directive_id == directive.id

      rows = self.class.where(id: id, locked_by_directive_id: nil)
                       .update_all(locked_by_directive_id: directive.id)
      if rows == 0
        reload
        raise LockConflict, "Facility #{id} already locked by directive #{locked_by_directive_id}"
      end

      reload
      true
    end

    # Atomically unlocks the facility for a specific directive.
    # Uses WHERE guard to prevent clearing a lock held by a different directive.
    def unlock!(directive = nil)
      if directive
        rows = self.class.where(id: id, locked_by_directive_id: directive.id)
                         .update_all(locked_by_directive_id: nil)
        reload if rows > 0
      else
        update!(locked_by_directive_id: nil)
      end
    end
  end
end
