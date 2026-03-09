class AgentDeployment < ApplicationRecord
  ACTIVE_STATUS = "active".freeze

  belongs_to :agent_program

  has_many :agent_rpc_invocations, dependent: :destroy
  has_many :agent_rpc_sessions, dependent: :destroy
  has_many :conversation_runs, dependent: :nullify
  has_many :run_drafts, dependent: :nullify

  before_validation :normalize_snapshots

  validates :transport_kind, presence: true
  validates :deployment_bearer_secret_ref, presence: true
  validates :contract_fingerprint, presence: true
  validates :deployment_fingerprint, presence: true
  validates :protocol_version, presence: true
  validates :status, presence: true
  validates :health_status, presence: true
  validates :supported_methods, presence: true

  validate :one_active_deployment_per_program, if: :active?

  def active?
    status == ACTIVE_STATUS
  end

  private

    def normalize_snapshots
      self.supported_methods = Array(supported_methods).map(&:to_s).reject(&:blank?).uniq
      self.transport_config = normalize_hash(self[:transport_config])
      self.manifest_snapshot = normalize_hash(self[:manifest_snapshot])
      self.schema_snapshot = normalize_hash(self[:schema_snapshot])
      self.capability_snapshot = normalize_hash(self[:capability_snapshot])
      self.inspection_details = normalize_hash(self[:inspection_details])
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def one_active_deployment_per_program
      scope = self.class.where(agent_program_id: agent_program_id, status: ACTIVE_STATUS)
      scope = scope.where.not(id: id) if persisted?
      errors.add(:agent_program_id, :taken) if scope.exists?
    end
end
