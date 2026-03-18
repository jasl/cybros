class LaneProcess < ApplicationRecord
  STARTING = "starting".freeze
  RUNNING = "running".freeze
  FAILED = "failed".freeze
  EXITED = "exited".freeze
  KILLED = "killed".freeze
  LOST = "lost".freeze

  AGENT = "agent".freeze
  USER = "user".freeze

  STATUSES = [STARTING, RUNNING, FAILED, EXITED, KILLED, LOST].freeze
  ACTIVE_STATUSES = [STARTING, RUNNING].freeze
  TERMINAL_STATUSES = [FAILED, EXITED, KILLED, LOST].freeze
  STARTED_BY_TYPES = [AGENT, USER].freeze

  belongs_to :conversation
  belongs_to :lane, class_name: "DAG::Lane"
  belongs_to :owner_turn, class_name: "DAG::Turn", optional: true

  enum :status, STATUSES.index_by(&:itself)

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  before_validation :normalize_attributes

  validates :conversation, presence: true
  validates :lane, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :started_by_type, presence: true, inclusion: { in: STARTED_BY_TYPES }

  validate :lane_must_belong_to_conversation

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def display_title
    title.presence || command.to_s
  end

  def manageable_by_lane?(lane)
    lane.present? && lane_id.to_s == lane.id.to_s
  end

  def conflict_for_lane?(lane)
    lane.present? && lane_id.to_s != lane.id.to_s
  end

  def self.normalize_port_hints(value)
    Array(value).filter_map do |entry|
      port = Integer(entry, exception: false)
      port if port.present? && port.positive?
    end.uniq
  end

  private

    def normalize_attributes
      self.started_by_type = started_by_type.to_s.strip.presence
      self.status = status.to_s.strip.presence
      self.title = title.to_s.strip.presence
      self.command = command.to_s.strip.presence
      self.cwd = cwd.to_s.strip.presence
      self.log_path = log_path.to_s.strip.presence
      self.port_hints = self.class.normalize_port_hints(port_hints)
      self.summary_json = normalize_json(summary_json)
    end

    def normalize_json(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), out|
          out[key.to_s] = normalize_json(nested_value)
        end
      when Array
        value.map { |entry| normalize_json(entry) }
      when nil
        {}
      else
        value
      end
    end

    def lane_must_belong_to_conversation
      return if lane.blank? || conversation.blank?
      return if lane.graph_id.to_s == conversation.root_graph.id.to_s

      errors.add(:lane, "must belong to the conversation graph")
    end
end
