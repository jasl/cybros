require "test_helper"

class Conduits::DiffBlobCleanupJobTest < ActiveSupport::TestCase
  def test_purges_only_expired_diff_blobs
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

    directive.diff_blob.attach(
      io: StringIO.new("diff"),
      filename: "diff.patch",
      content_type: "text/x-diff"
    )
    assert directive.diff_blob.attached?

    attachment = directive.diff_blob_attachment
    attachment.update_columns(created_at: 40.days.ago)

    Conduits::DiffBlobCleanupJob.perform_now(
      ttl_days: 30,
      batch_size: 100,
      sleep_seconds: 0
    )

    directive.reload
    assert_not directive.diff_blob.attached?
  end
end
