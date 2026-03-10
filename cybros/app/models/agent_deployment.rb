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

  validate :managed_local_transport_config_must_be_consistent
  validate :one_active_deployment_per_program, if: :active?

  scope :active_healthy, -> { where(status: ACTIVE_STATUS, health_status: "healthy") }

  def active?
    status == ACTIVE_STATUS
  end

  def allocated_port
    Integer(transport_config["port"], exception: false)
  end

  def runtime_config_path
    transport_config["runtime_config_path"].to_s.presence
  end

  def managed_local_http_jsonrpc?
    transport_kind.to_s == "http_jsonrpc" && allocated_port.present?
  end

  def close_open_rpc_sessions!(at: Time.current.change(usec: 0))
    agent_rpc_sessions.where(status: "open").update_all(status: "closed", updated_at: at)
  end

  def self.local_endpoint_url(host:, port:, rpc_path:)
    normalized_path = rpc_path.to_s
    normalized_path = "/#{normalized_path}" unless normalized_path.start_with?("/")
    "http://#{host}:#{port}#{normalized_path}"
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

    def managed_local_transport_config_must_be_consistent
      return unless transport_kind.to_s == "http_jsonrpc"
      return unless transport_config["port"].present? || transport_config["runtime_config_path"].present?

      port = allocated_port
      if port.nil?
        errors.add(:transport_config, "must include an integer port for managed local endpoints")
        return
      end

      errors.add(:transport_config, "must include runtime_config_path for managed local endpoints") if runtime_config_path.blank?

      host = transport_config["host"].to_s.presence || AgentDeployments::EndpointAllocator::DEFAULT_HOST
      rpc_path = transport_config["rpc_path"].to_s.presence || AgentDeployments::EndpointAllocator::DEFAULT_RPC_PATH
      expected_endpoint_url = self.class.local_endpoint_url(host: host, port: port, rpc_path: rpc_path)

      return if endpoint_url.to_s.blank? || endpoint_url.to_s == expected_endpoint_url

      errors.add(:endpoint_url, "must match the managed local endpoint allocation")
    end
end
