class ConversationRun < ApplicationRecord
  STATES = %w[queued running succeeded failed canceled].freeze
  SNAPSHOT_FIELDS = %i[
    snapshot_version
    initiated_by_user_id
    effective_permission_mode
    agent_program_id
    contract_fingerprint
    agent_deployment_id
    deployment_fingerprint
    deployment_activated_at
    provider_credential_id
    execution_target_id
    selected_model_ref
    effective_public_settings
    effective_agent_config
    agent_config_schema_fingerprint
    effective_policy
    runtime_governors
    snapshot
  ].freeze

  belongs_to :conversation
  belongs_to :initiated_by_user, class_name: "User", optional: true
  belongs_to :agent_program, optional: true
  belongs_to :agent_deployment, optional: true
  belongs_to :provider_credential, class_name: "LLMProviderCredential", optional: true
  belongs_to :execution_target, optional: true
  has_one :automation_run, dependent: :nullify

  attr_readonly(*SNAPSHOT_FIELDS)

  validates :dag_node_id, presence: true
  validates :state, presence: true, inclusion: { in: STATES }
  validates :queued_at, presence: true
  validates :snapshot_version, presence: true
  validates :effective_permission_mode, presence: true
  validates :agent_program, presence: true
  validates :contract_fingerprint, presence: true
  validates :agent_deployment, presence: true
  validates :deployment_fingerprint, presence: true
  validates :deployment_activated_at, presence: true

  validate :binding_consistency

  before_validation :normalize_snapshot_payloads, on: :create

  def self.latest_for_node(node_or_id)
    node_id = node_or_id.respond_to?(:id) ? node_or_id.id : node_or_id
    return nil if node_id.blank?

    where(dag_node_id: node_id).order(:id).last
  end

  def queued? = state == "queued"
  def running? = state == "running"
  def succeeded? = state == "succeeded"
  def failed? = state == "failed"
  def canceled? = state == "canceled"
  def programmable? = snapshot["draft"].is_a?(Hash)
  def compose_invocation_id = "conversation_run:#{id}:turn.compose"
  def handle_error_invocation_id = "conversation_run:#{id}:turn.handle_error"
  def execution_capacity_snapshot
    runtime_governors["execution_capacity"] if runtime_governors.is_a?(Hash)
  end
  def execution_capacity_governed? = execution_capacity_snapshot.is_a?(Hash)

  def waiting_for_capacity?
    queued? &&
      RuntimeWait.parked.exists?(
        owner_type: self.class.name,
        owner_id: id,
        reason_type: "execution_capacity",
      )
  end

  def runtime_state
    waiting_for_capacity? ? "waiting_for_capacity" : state
  end

  def mark_running!(at: Time.current)
    update!(state: "running", started_at: at) if queued?
  end

  def mark_succeeded!(at: Time.current)
    update!(state: "succeeded", finished_at: at) if running? || queued?
  end

  def mark_failed!(message:, at: Time.current)
    payload = error.is_a?(Hash) ? error : {}
    payload = payload.deep_stringify_keys
    payload["message"] = message.to_s
    update!(state: "failed", finished_at: at, error: payload) if running? || queued?
  end

  def mark_canceled!(at: Time.current)
    update!(state: "canceled", finished_at: at) if running? || queued?
  end

  private

    def normalize_snapshot_payloads
      self.effective_public_settings = normalize_hash(self[:effective_public_settings])
      self.effective_agent_config = normalize_hash(self[:effective_agent_config])
      self.effective_policy = normalize_hash(self[:effective_policy])
      self.runtime_governors = normalize_hash(self[:runtime_governors])
      self.snapshot = normalize_hash(self[:snapshot])
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def binding_consistency
      return if agent_program.blank? || agent_deployment.blank?

      if agent_deployment.agent_program_id != agent_program_id
        errors.add(:agent_deployment, "must belong to the selected agent program")
      end

      if agent_deployment.contract_fingerprint != contract_fingerprint
        errors.add(:contract_fingerprint, "must match the deployed contract")
      end

      if agent_deployment.deployment_fingerprint != deployment_fingerprint
        errors.add(:deployment_fingerprint, "must match the selected deployment")
      end
    end
end
