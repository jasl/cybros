module Conduits
  module V1
    class TerritoriesController < Conduits::V1::ApplicationController
      skip_before_action :authenticate_territory!, only: %i[enroll]

      # POST /conduits/v1/territories/enroll
      #
      # Validates enrollment token, creates territory, and optionally issues mTLS client cert.
      # All mutations are wrapped in a transaction for atomicity.
      #
      # Params: { enroll_token, name, labels, metadata, csr_pem? }
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
          mtls_client_cert_pem: issued&.client_cert_pem,
          ca_bundle_pem: issued&.ca_bundle_pem,
          config: {
            poll_interval_seconds: 2,
            heartbeat_interval_seconds: 30,
            lease_ttl_seconds: Conduits::PollService::DEFAULT_LEASE_TTL,
          },
        }.compact, status: :created
      rescue ArgumentError => e
        render json: { error: "invalid_param", detail: e.message }, status: :unprocessable_entity
      end

      # POST /conduits/v1/territories/heartbeat
      #
      # Territory-level presence registration.
      # Params: { nexus_version, labels, capacity, running_directives_count }
      def heartbeat
        current_territory.record_heartbeat!(
          nexus_version: params[:nexus_version],
          capacity: params_to_h(params[:capacity]),
          labels: params_to_h(params[:labels])
        )

        render json: { ok: true, territory_id: current_territory.id }
      end
    end
  end
end
