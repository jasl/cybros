module RuntimeGovernance
  class ObservabilityFeed
    DEFAULT_RECENT_LIMIT = 10
    RECENT_WINDOW = 24.hours
    WAIT_REASON_LABELS = {
      "provider_limit" => "Provider limit",
      "execution_capacity" => "Execution capacity",
      "deployment_backoff" => "Deployment backoff",
    }.freeze
    SUBJECT_KIND_LABELS = {
      "llm_provider_credential" => "Provider credential",
      "execution_location" => "Execution location",
      "execution_target" => "Execution target",
      "agent_deployment" => "Agent deployment",
    }.freeze

    def self.build(recent_limit: DEFAULT_RECENT_LIMIT, recent_window: RECENT_WINDOW)
      new(recent_limit: recent_limit, recent_window: recent_window).build
    end

    def self.call(recent_limit: DEFAULT_RECENT_LIMIT, recent_window: RECENT_WINDOW)
      build_feed = build(recent_limit: recent_limit, recent_window: recent_window)

      {
        "parked_wait_counts" => build_feed.fetch(:parked_wait_counts),
        "subjects" => build_feed.fetch(:subject_groups).map { |group| flatten_subject_group(group) },
      }
    end

    def initialize(recent_limit:, recent_window:)
      @recent_limit = recent_limit
      @recent_window = recent_window
      @subjects = {}
      @owner_labels = {}
    end

    def build
      current_parked_waits.each { |wait| append_wait!(wait, bucket: :current_parked_waits) }
      recent_wait_recovery.each { |wait| append_wait!(wait, bucket: :recent_wait_recovery) }
      recent_lease_recovery.each { |lease| append_lease!(lease) }
      recent_provider_activity.each { |reservation| append_provider_activity!(reservation) }
      recent_execution_capacity_denials.each { |run| append_execution_capacity_denial!(run) }

      {
        parked_wait_counts: parked_wait_counts,
        subject_groups: subject_groups,
      }
    end

    private

      attr_reader :recent_limit, :recent_window

      def current_parked_waits
        @current_parked_waits ||= RuntimeWait.parked.order(:retry_at, :ordering_key, :created_at, :id).to_a
      end

      def recent_wait_recovery
        @recent_wait_recovery ||= RuntimeWait.where(status: %w[resumed cancelled expired]).where("updated_at >= ?", recent_cutoff).order(updated_at: :desc, id: :desc).to_a
      end

      def recent_lease_recovery
        @recent_lease_recovery ||= ExecutionCapacityLease.where(status: %w[released expired]).where("updated_at >= ?", recent_cutoff).order(updated_at: :desc, id: :desc).to_a
      end

      def recent_provider_activity
        @recent_provider_activity ||= ProviderBudgetReservation.where(status: %w[settled released expired]).where("updated_at >= ?", recent_cutoff).order(updated_at: :desc, id: :desc).to_a
      end

      def recent_execution_capacity_denials
        @recent_execution_capacity_denials ||=
          ConversationRun.where(state: "failed")
            .includes(:execution_target)
            .where("updated_at >= ?", recent_cutoff)
            .order(updated_at: :desc, id: :desc)
            .to_a
            .select { |run| run.error.is_a?(Hash) && run.error["message"].to_s.include?("execution_capacity_denied") }
      end

      def parked_wait_counts
        RuntimeWait::REASONS.index_with { 0 }.merge(RuntimeWait.parked.group(:reason_type).count)
      end

      def subject_groups
        @subjects.values.map { |group| trim_group(group) }.sort_by do |group|
          [
            -group.fetch(:current_parked_waits).size,
            -(group.fetch(:latest_activity_at)&.to_i || 0),
            group.fetch(:subject_label).to_s.downcase,
          ]
        end
      end

      def trim_group(group)
        group.merge(
          current_parked_waits: group.fetch(:current_parked_waits).sort_by { |wait| [wait.fetch(:retry_at), wait.fetch(:id)] },
          recent_wait_recovery: trim_recent_bucket(group.fetch(:recent_wait_recovery)),
          recent_lease_recovery: trim_recent_bucket(group.fetch(:recent_lease_recovery)),
          recent_provider_activity: trim_recent_bucket(group.fetch(:recent_provider_activity)),
          recent_execution_capacity_denials: trim_recent_bucket(group.fetch(:recent_execution_capacity_denials)),
        )
      end

      def trim_recent_bucket(events)
        events.sort_by { |event| [event.fetch(:occurred_at), event_sort_key(event)] }.reverse.first(recent_limit)
      end

      def append_wait!(wait, bucket:)
        group = group_for(subject_type: wait.subject_type, subject_id: wait.subject_id)
        group.fetch(bucket) << {
          id: wait.id,
          reason_type: wait.reason_type,
          reason_label: WAIT_REASON_LABELS.fetch(wait.reason_type, wait.reason_type.humanize),
          owner_type: wait.owner_type,
          owner_id: wait.owner_id,
          owner_label: owner_label_for(wait.owner_type, wait.owner_id),
          retry_at: wait.retry_at,
          status: wait.status,
          details: wait.details,
          details_summary: wait_details_summary(wait.details),
          occurred_at: bucket == :current_parked_waits ? wait.created_at : wait.updated_at,
        }
        touch_group!(group, bucket == :current_parked_waits ? wait.created_at : wait.updated_at)
      end

      def append_lease!(lease)
        group = group_for(subject_type: lease.subject_type, subject_id: lease.subject_id)
        group.fetch(:recent_lease_recovery) << {
          id: lease.id,
          status: lease.status,
          execution_request_id: lease.execution_request_id,
          holder_type: lease.holder_type,
          holder_id: lease.holder_id,
          holder_label: owner_label_for(lease.holder_type, lease.holder_id),
          slots: lease.slots,
          lease_expires_at: lease.lease_expires_at,
          occurred_at: lease.updated_at,
        }
        touch_group!(group, lease.updated_at)
      end

      def append_provider_activity!(reservation)
        group = group_for(subject_type: "llm_provider_credential", subject_id: reservation.provider_credential_id)
        group.fetch(:recent_provider_activity) << {
          id: reservation.id,
          status: reservation.status,
          request_id: reservation.provider_request_id,
          estimated_tokens: reservation.estimated_tokens,
          actual_tokens: reservation.actual_tokens,
          reserved_until: reservation.reserved_until,
          occurred_at: reservation.updated_at,
        }
        touch_group!(group, reservation.updated_at)
      end

      def append_execution_capacity_denial!(run)
        snapshot = run.execution_capacity_snapshot
        return unless snapshot.is_a?(Hash)

        group = group_for(subject_type: snapshot["scope_type"], subject_id: snapshot["scope_id"])
        group.fetch(:recent_execution_capacity_denials) << {
          run_id: run.id,
          message: run.error["message"].to_s,
          execution_target_id: snapshot["execution_target_id"],
          occurred_at: run.updated_at,
        }
        touch_group!(group, run.updated_at)
      end

      def group_for(subject_type:, subject_id:)
        key = [subject_type.to_s, subject_id.to_s]
        @subjects[key] ||= begin
          subject_type = subject_type.to_s
          subject_id = subject_id.to_s
          {
            subject_type: subject_type,
            subject_id: subject_id,
            subject_kind: SUBJECT_KIND_LABELS.fetch(subject_type, subject_type.humanize),
            subject_label: subject_label_for(subject_type, subject_id),
            subject_subtitle: subject_subtitle_for(subject_type, subject_id),
            current_parked_waits: [],
            recent_wait_recovery: [],
            recent_lease_recovery: [],
            recent_provider_activity: [],
            recent_execution_capacity_denials: [],
            latest_activity_at: nil,
          }
        end
      end

      def touch_group!(group, at)
        return if at.blank?
        return if group[:latest_activity_at].present? && group[:latest_activity_at] >= at

        group[:latest_activity_at] = at
      end

      def wait_details_summary(details)
        payload = details.is_a?(Hash) ? details.deep_stringify_keys : {}
        return payload["provider_request_id"] if payload["provider_request_id"].present?
        return payload["execution_request_id"] if payload["execution_request_id"].present?
        return "attempt #{payload["attempt"]}" if payload["attempt"].present?

        payload.presence
      end

      def owner_label_for(owner_type, owner_id)
        key = [owner_type.to_s, owner_id.to_s]
        @owner_labels[key] ||= begin
          case owner_type.to_s
          when "ConversationRun"
            run = ConversationRun.find_by(id: owner_id)
            run.present? ? "Run #{run.id} (#{run.runtime_state})" : "Conversation run #{owner_id}"
          when "RunDraft"
            "Draft #{owner_id}"
          when "AgentDeployment"
            deployment = AgentDeployment.includes(:agent_program).find_by(id: owner_id)
            deployment.present? ? "#{deployment.agent_program.name} deployment" : "Deployment #{owner_id}"
          else
            "#{owner_type} #{owner_id}"
          end
        end
      end

      def subject_label_for(subject_type, subject_id)
        case subject_type
        when "llm_provider_credential"
          LLMProviderCredential.find_by(id: subject_id)&.provider_key.to_s.presence || "Provider credential #{subject_id}"
        when "execution_location"
          ExecutionLocation.find_by(id: subject_id)&.name.to_s.presence || "Execution location #{subject_id}"
        when "execution_target"
          ExecutionTarget.find_by(id: subject_id)&.name.to_s.presence || "Execution target #{subject_id}"
        when "agent_deployment"
          deployment = AgentDeployment.includes(:agent_program).find_by(id: subject_id)
          deployment&.agent_program&.name.to_s.presence || "Deployment #{subject_id}"
        else
          "#{subject_type} #{subject_id}"
        end
      end

      def subject_subtitle_for(subject_type, subject_id)
        case subject_type
        when "llm_provider_credential"
          credential = LLMProviderCredential.find_by(id: subject_id)
          return if credential.blank?

          [credential.credential_type, credential.status].compact.join(" • ")
        when "execution_location"
          location = ExecutionLocation.find_by(id: subject_id)
          return if location.blank?

          [location.platform, location.environment].compact.join(" • ")
        when "execution_target"
          target = ExecutionTarget.includes(:execution_location, :workspace).find_by(id: subject_id)
          return if target.blank?

          [target.execution_location&.name, target.workspace&.name].compact.join(" • ")
        when "agent_deployment"
          deployment = AgentDeployment.find_by(id: subject_id)
          return if deployment.blank?

          [deployment.status, deployment.health_status].compact.join(" • ")
        end
      end

      def recent_cutoff
        Time.current - recent_window
      end

      def event_sort_key(event)
        event[:id] || event[:run_id] || event[:execution_request_id] || event[:request_id] || event[:owner_id] || event[:holder_id]
      end

      def self.flatten_subject_group(group)
        parked_waits =
          group.fetch(:current_parked_waits).map do |wait|
            {
              "id" => wait.fetch(:id),
              "reason_type" => wait.fetch(:reason_type),
              "status" => wait.fetch(:status),
              "owner_type" => wait.fetch(:owner_type),
              "owner_id" => wait.fetch(:owner_id),
              "retry_at" => wait.fetch(:retry_at).utc.iso8601(6),
              "details" => normalize_hash(wait.fetch(:details)),
            }
          end

        recent_events =
          group.fetch(:recent_wait_recovery).map do |event|
            {
              "id" => event.fetch(:id),
              "kind" => "wait_#{event.fetch(:status)}",
              "occurred_at" => event.fetch(:occurred_at).utc.iso8601(6),
              "summary" => "#{event.fetch(:reason_type)} wait #{event.fetch(:status)}",
              "owner_type" => event.fetch(:owner_type),
              "owner_id" => event.fetch(:owner_id),
            }
          end
        recent_events.concat(
          group.fetch(:recent_lease_recovery).map do |event|
            {
              "id" => event.fetch(:id),
              "kind" => "lease_#{event.fetch(:status)}",
              "occurred_at" => event.fetch(:occurred_at).utc.iso8601(6),
              "summary" => "execution_capacity lease #{event.fetch(:status)}",
              "execution_request_id" => event.fetch(:execution_request_id),
            }
          end,
        )
        recent_events.concat(
          group.fetch(:recent_provider_activity).map do |event|
            {
              "id" => event.fetch(:id),
              "kind" => "reservation_#{event.fetch(:status)}",
              "occurred_at" => event.fetch(:occurred_at).utc.iso8601(6),
              "summary" => "provider reservation #{event.fetch(:status)}",
              "provider_request_id" => event.fetch(:request_id),
            }
          end,
        )
        recent_events.concat(
          group.fetch(:recent_execution_capacity_denials).map do |event|
            {
              "id" => event.fetch(:run_id),
              "kind" => "execution_capacity_denied",
              "occurred_at" => event.fetch(:occurred_at).utc.iso8601(6),
              "summary" => event.fetch(:message),
              "conversation_run_id" => event.fetch(:run_id),
            }
          end,
        )

        {
          "subject_type" => group.fetch(:subject_type),
          "subject_id" => group.fetch(:subject_id),
          "subject_kind" => group.fetch(:subject_kind),
          "subject_label" => group.fetch(:subject_label),
          "subject_detail" => group[:subject_subtitle],
          "parked_waits" => parked_waits,
          "recent_events" => recent_events.sort_by { |event| [event.fetch("occurred_at"), event.fetch("kind"), event.fetch("id").to_s] }.reverse,
        }
      end

      def self.normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end
  end
end
