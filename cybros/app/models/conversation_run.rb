# frozen_string_literal: true

class ConversationRun < ApplicationRecord
  STATES = %w[queued running succeeded failed canceled].freeze

  belongs_to :conversation

  validates :dag_node_id, presence: true
  validates :state, presence: true, inclusion: { in: STATES }
  validates :queued_at, presence: true

  def queued? = state == "queued"
  def running? = state == "running"
  def succeeded? = state == "succeeded"
  def failed? = state == "failed"
  def canceled? = state == "canceled"

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
end

