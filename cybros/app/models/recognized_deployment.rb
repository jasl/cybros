class RecognizedDeployment < ApplicationRecord
  belongs_to :agent

  has_many :agent_rpc_invocations, dependent: :nullify
  has_many :agent_rpc_sessions, dependent: :nullify
  has_many :conversation_runs, dependent: :nullify
  has_many :run_drafts, dependent: :nullify

  before_validation :normalize_payloads

  validates :identity_digest, presence: true
  validates :recognized_deployment_key, presence: true, uniqueness: true
  validates :deployment_fingerprint, presence: true
  validates :protocol_version, presence: true
  validates :supported_methods, presence: true

  scope :active, -> { where(retired_at: nil) }

  def self.recognize!(agent:, deployment:, initialize_result: nil, capability_snapshot: nil)
    Cybros::ProgrammableAgent::RecognizedDeploymentResolver.resolve!(
      agent: agent,
      deployment: deployment,
      initialize_result: initialize_result,
      capability_snapshot: capability_snapshot,
    )
  end

  def retire!
    update!(
      retired_at: Time.current,
      hostname: nil,
      container_id: nil,
      git_sha: nil,
      build_id: nil,
      image_digest: nil,
    )
  end

  def retired?
    retired_at.present?
  end

  def observed_supported_methods
    Array(capability_snapshot.dig("observed_runtime_identity", "supported_methods")).presence ||
      Array(supported_methods)
  end

  def supports_workspace_attachment_materialization?
    agent&.supports_workspace_attachment_materialization? == true
  end

  def supports_remote_attachment_import?
    Array(observed_supported_methods).map(&:to_s).include?(Agents::Protocol::ATTACHMENT_IMPORT_METHOD)
  end

  def supports_conversation_attachments?
    supports_workspace_attachment_materialization? || supports_remote_attachment_import?
  end

  def self.identity_payload_from(deployment:)
    agent = deployment if deployment.is_a?(Agent)
    agent ||= deployment.agent if deployment.respond_to?(:agent)

    Cybros::ProgrammableAgent::RecognizedDeploymentResolver.new(
      agent: agent,
      deployment: deployment,
      initialize_result: nil,
      capability_snapshot: deployment.respond_to?(:capability_snapshot) ? deployment.capability_snapshot : {},
    ).identity_payload
  end

  def self.digest_for(payload)
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize_value(payload)))}"
  end

  def self.normalize_hash(value)
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end

  def self.parse_time(value)
    text = value.to_s.strip
    return nil if text.blank?

    Time.iso8601(text)
  rescue ArgumentError
    nil
  end

  def self.canonicalize_value(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested_value), canonical|
        canonical[key.to_s] = canonicalize_value(nested_value)
      end.sort.to_h
    when Array
      value.map { |entry| canonicalize_value(entry) }
    else
      value
    end
  end

  private

    def normalize_payloads
      self.supported_methods = Array(supported_methods).map(&:to_s).reject(&:blank?).uniq
      self.capability_snapshot = self.class.normalize_hash(self[:capability_snapshot])
      self.supports_upload = supports_remote_attachment_import?
    end
end
