require "json"
require "time"
require "uri"

module Cybros
  module LLM
    class CodexOAuthError < StandardError
      attr_reader :error_code, :details

      def initialize(message, error_code: nil, details: nil)
        super(message)
        @error_code = error_code
        @details = details
      end
    end

    module CodexOAuth
      BASE_URL = "https://auth.openai.com"
      USER_CODE_URL = "#{BASE_URL}/api/accounts/deviceauth/usercode"
      DEVICEAUTH_TOKEN_URL = "#{BASE_URL}/api/accounts/deviceauth/token"
      OAUTH_TOKEN_URL = "#{BASE_URL}/oauth/token"
      REDIRECT_URI = "#{BASE_URL}/deviceauth/callback"
      CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
      VERIFICATION_URI = "#{BASE_URL}/codex/device"

      module_function

      def start_device_flow!(http: ::HTTPX)
        status, body =
          post_json!(
            http: http,
            url: USER_CODE_URL,
            json: { client_id: CLIENT_ID },
          )

        unless status == 200
          raise CodexOAuthError.new("Device auth usercode failed", details: { status: status, body: body })
        end

        user_code = body["user_code"] || body["usercode"]
        {
          "device_auth_id" => fetch_required_field!(body, "device_auth_id"),
          "user_code" => fetch_required_value!(body, "user_code", user_code),
          "verification_uri" => VERIFICATION_URI,
          "interval" => body.fetch("interval", 5),
          "expires_at" => body["expires_at"],
        }.compact
      end

      def poll_device_flow!(device_auth_id:, user_code:, http: ::HTTPX)
        status, body =
          post_json!(
            http: http,
            url: DEVICEAUTH_TOKEN_URL,
            json: { device_auth_id: device_auth_id.to_s, user_code: user_code.to_s },
          )

        return { status: :pending, raw: body } if status == 403 || status == 404

        unless status == 200
          raise CodexOAuthError.new("Device flow poll failed", details: { status: status, body: body })
        end

        authorization_code = fetch_required_field!(body, "authorization_code").to_s
        code_verifier = fetch_required_field!(body, "code_verifier").to_s

        token_body =
          post_form!(
            http: http,
            url: OAUTH_TOKEN_URL,
            form: {
              grant_type: "authorization_code",
              client_id: CLIENT_ID,
              code: authorization_code,
              code_verifier: code_verifier,
              redirect_uri: REDIRECT_URI,
            },
            allow_oauth_error: true,
          )

        if (err = oauth_error_code(token_body))
          raise CodexOAuthError.new("Device flow token exchange failed: #{err}", error_code: err, details: { body: token_body })
        end

        tokens_from_token_response(token_body)
      end

      def refresh!(refresh_token:, http: ::HTTPX)
        body =
          post_form!(
            http: http,
            url: OAUTH_TOKEN_URL,
            form: {
              grant_type: "refresh_token",
              refresh_token: refresh_token.to_s,
              client_id: CLIENT_ID,
            },
            allow_oauth_error: true,
          )

        if (err = oauth_error_code(body))
          raise CodexOAuthError.new("Refresh failed: #{err}", error_code: err, details: { body: body })
        end

        tokens_from_token_response(body)
      end

      def refresh_if_needed!(credential, http: ::HTTPX, now: Time.current, buffer_s: 60)
        return credential unless credential
        return credential unless credential.credential_type.to_s == "oauth_codex"

        expires_at = credential.expires_at
        return credential if expires_at.is_a?(Time) && expires_at > (now + buffer_s)

        rt = credential.refresh_token.to_s
        raise CodexOAuthError.new("Missing refresh_token for refresh", error_code: "missing_refresh_token") if rt.empty?

        refresh_result = refresh!(refresh_token: rt, http: http)
        tokens = refresh_result.fetch(:tokens)

        credential.update!(
          access_token: tokens.fetch("access_token"),
          refresh_token: tokens.fetch("refresh_token", credential.refresh_token),
          expires_at: tokens.fetch("expires_at"),
          account_id: tokens.fetch("account_id", credential.account_id),
        )

        credential
      end

      def tokens_from_token_response(body)
        access_token = fetch_required_field!(body, "access_token").to_s
        refresh_token = body.fetch("refresh_token", nil).to_s
        expires_in = Integer(body.fetch("expires_in", 0), exception: false) || 0
        account_id = body["account_id"] || body["chatgpt_account_id"] || body["workspace_id"]
        account_id ||= extract_account_id_from_id_token(body["id_token"])

        out = { "access_token" => access_token }
        out["refresh_token"] = refresh_token unless refresh_token.empty?
        out["expires_at"] = Time.current + expires_in if expires_in.positive?
        out["account_id"] = account_id.to_s if account_id
        out["token_type"] = body["token_type"].to_s if body["token_type"]
        out["scope"] = body["scope"].to_s if body["scope"]
        { status: :authorized, tokens: out, raw: body }
      end

      def extract_account_id_from_id_token(id_token)
        token = id_token.to_s
        return nil if token.empty?

        # JWT: header.payload.signature (base64url). We only extract payload claims for convenience.
        payload_b64 = token.split(".", 3)[1].to_s
        return nil if payload_b64.empty?

        json_str = Base64.urlsafe_decode64(payload_b64)
        claims = JSON.parse(json_str)
        return nil unless claims.is_a?(Hash)

        claims["account_id"] || claims["chatgpt_account_id"] || claims["workspace_id"]
      rescue StandardError
        nil
      end

      def post_form!(http:, url:, form:, allow_oauth_error: false)
        payload = URI.encode_www_form(form)
        resp =
          http
            .with(headers: { "Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json" })
            .post(url, body: payload)

        status = resp.status.to_i
        body_str = resp.to_s
        parsed = body_str.to_s.strip.empty? ? {} : JSON.parse(body_str)
        parsed = {} unless parsed.is_a?(Hash)

        if status >= 200 && status < 300
          return parsed
        end

        return parsed if allow_oauth_error && oauth_error_code(parsed)

        message = parsed.dig("error_description") || parsed.dig("error", "message") || parsed["error"] || "HTTP #{status}"
        raise CodexOAuthError.new(message.to_s, details: { status: status, body: parsed })
      rescue JSON::ParserError => e
        raise CodexOAuthError.new(
          "Failed to parse OAuth response JSON: #{e.message}",
          details: { url: url.to_s, status: (resp&.status.to_i rescue nil), body_prefix: body_str.to_s[0, 200] },
        )
      end

      def post_json!(http:, url:, json:)
        resp =
          http
            .with(headers: { "Content-Type" => "application/json", "Accept" => "application/json" })
            .post(url, body: JSON.generate(json))

        status = resp.status.to_i
        body_str = resp.to_s
        parsed = body_str.to_s.strip.empty? ? {} : JSON.parse(body_str)
        parsed = {} unless parsed.is_a?(Hash)
        [status, parsed]
      rescue JSON::ParserError => e
        raise CodexOAuthError.new(
          "Failed to parse OAuth response JSON: #{e.message}",
          details: { url: url.to_s, status: (resp&.status.to_i rescue nil), body_prefix: body_str.to_s[0, 200] },
        )
      end

      def oauth_error_code(body)
        return nil unless body.is_a?(Hash)

        code = body["error"]
        code = code.to_s.strip
        code.empty? ? nil : code
      end

      def fetch_required_field!(body, key)
        fetch_required_value!(body, key, body.fetch(key))
      rescue KeyError
        raise_missing_field!(body, key)
      end

      def fetch_required_value!(body, key, value)
        string = value.to_s
        raise_missing_field!(body, key) if string.strip.empty?

        value
      end

      def raise_missing_field!(body, key)
        raise CodexOAuthError.new(
                "OAuth response missing required field: #{key}",
                error_code: "invalid_response",
                details: { field: key.to_s, body: body },
              )
      end
    end
  end
end
