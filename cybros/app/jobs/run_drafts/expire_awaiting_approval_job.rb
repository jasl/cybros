module RunDrafts
  class ExpireAwaitingApprovalJob < ApplicationJob
    queue_as :default

    def perform(run_draft_id)
      draft = RunDraft.find_by(id: run_draft_id)
      return if draft.nil?

      RunDrafts::ApprovalExpiryService.expire!(draft: draft)
    end
  end
end
