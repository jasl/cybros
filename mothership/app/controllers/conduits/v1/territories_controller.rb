module Conduits
  module V1
    class TerritoriesController < Conduits::V1::ApplicationController
      skip_before_action :authenticate_territory!, only: %i[enroll]

      # POST /conduits/v1/territories/enroll
      #
      # Validates enrollment token, creates territory, and optionally issues mTLS client cert.
      # All mutations are wrapped in a transaction for atomicity.
      #
      # Params: { enroll_token, name, labels, metadata, csr_pem?, kind?, platform? }
      # Returns: { territory_id, config, mtls_client_cert_pem?, ca_bundle_pem? }
      def enroll
        token_record = Conduits::EnrollmentToken.find_usable(params[:enroll_token].to_s)

        unless token_record
          render json: { error: "invalid_token", detail: "enrollment token is invalid, expired, or already used" },
                 status: :unprocessable_entity
          return
        end

        territory = nil
        issued = nil

        ActiveRecord::Base.transaction do
          territory = Conduits::Territory.create!(
            account: token_record.account,
            name: params[:name].presence || "nexus-#{SecureRandom.hex(4)}",
            kind: params[:kind].presence || "server",
            platform: params[:platform].presence,
            display_name: params[:display_name].presence,
            labels: token_record.labels.merge(params_to_h(params[:labels])),
            capacity: params_to_h(params.dig(:metadata, :capacity))
          )

          territory.activate!
          token_record.use!

          if params[:csr_pem].present?
            issued = Conduits::Mtls::CertificateAuthority.issue_client_cert!(params[:csr_pem])
            territory.update!(client_cert_fingerprint: issued.fingerprint)
          end
        end

        render json: {
          territory_id: territory.id,
          kind: territory.kind,
          mtls_client_cert_pem: issued&.client_cert_pem,
          ca_bundle_pem: issued&.ca_bundle_pem,
          config: {
            poll_interval_seconds: 2,
            heartbeat_interval_seconds: Conduits::DirectiveNotifier::HEARTBEAT_INTERVAL_REST,
            heartbeat_interval_ws_seconds: Conduits::DirectiveNotifier::HEARTBEAT_INTERVAL_WS,
            lease_ttl_seconds: Conduits::PollService::DEFAULT_LEASE_TTL,
            cable_url: cable_url,
          },
        }.compact, status: :created
      rescue ArgumentError => e
        render json: { error: "invalid_param", detail: e.message }, status: :unprocessable_entity
      end

      # POST /conduits/v1/territories/heartbeat
      #
      # Territory-level presence registration.
      # Params: { nexus_version, labels, capacity, capabilities?, runtime_status?, bridge_entities? }
      #
      # runtime_status: {
      #   running_directives: 2,
      #   running_commands: 1,
      #   directive_ids: ["uuid1", "uuid2"],
      #   uptime_seconds: 86400,
      # }
      def heartbeat
        current_territory.record_heartbeat!(
          nexus_version: params[:nexus_version],
          capacity: params_to_h(params[:capacity]),
          labels: params_to_h(params[:labels]),
          capabilities: params[:capabilities].present? ? Array(params[:capabilities]) : nil,
          runtime_status: params[:runtime_status].present? ? params_to_h(params[:runtime_status]) : nil
        )

        # Sync bridge entities if reported
        if params[:bridge_entities].present? && current_territory.kind == "bridge"
          reported = Array(params[:bridge_entities]).map { |e| params_to_h(e) }
          Conduits::BridgeEntitySyncService.new.sync(
            territory: current_territory,
            reported_entities: reported
          )
        end

        ws_connected = current_territory.websocket_connected?

        render json: {
          ok: true,
          territory_id: current_territory.id,
          next_heartbeat_interval_seconds: ws_connected ?
            Conduits::DirectiveNotifier::HEARTBEAT_INTERVAL_WS :
            Conduits::DirectiveNotifier::HEARTBEAT_INTERVAL_REST,
          websocket_connected: ws_connected,
        }
      end

      private

      def cable_url
        ENV.fetch("ACTION_CABLE_URL") { ActionCable.server.config.url || "/cable" }
      end
    end
  end
end
