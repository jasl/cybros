require "test_helper"

class Conduits::LogChunkCleanupJobTest < ActiveSupport::TestCase
  def test_deletes_only_expired_log_chunks_in_batches
    account = Account.create!(name: "test-account")
    user = User.create!(account: account, name: "test-user")
    territory = Conduits::Territory.create!(account: account, name: "test-territory")
    facility = Conduits::Facility.create!(
      account: account,
      owner: user,
      territory: territory,
      kind: "repo",
      retention_policy: "keep_last_5"
    )

    directive = Conduits::Directive.create!(
      account: account,
      facility: facility,
      requested_by_user: user,
      command: "echo hi",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )

    expired = Conduits::LogChunk.create!(
      directive: directive,
      stream: "stdout",
      seq: 0,
      bytes: "old\n",
      bytesize: 4,
      truncated: false
    )
    expired.update_columns(created_at: 40.days.ago, updated_at: 40.days.ago)

    fresh = Conduits::LogChunk.create!(
      directive: directive,
      stream: "stdout",
      seq: 1,
      bytes: "new\n",
      bytesize: 4,
      truncated: false
    )
    fresh.update_columns(created_at: 1.day.ago, updated_at: 1.day.ago)

    assert_difference("Conduits::LogChunk.count", -1) do
      Conduits::LogChunkCleanupJob.perform_now(
        ttl_days: 30,
        batch_size: 1000,
        max_batches: 1,
        sleep_seconds: 0
      )
    end

    assert_not Conduits::LogChunk.exists?(expired.id)
    assert Conduits::LogChunk.exists?(fresh.id)
  end
end
