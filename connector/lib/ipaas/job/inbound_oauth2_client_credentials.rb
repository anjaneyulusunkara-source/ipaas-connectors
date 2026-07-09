module IPaaS
  module Job
    module InboundOAuth2ClientCredentials
      extend ActiveSupport::Concern
      extend IPaaS::Connector::Common::ProcRules::ProcSafe

      proc_safe :verify_inbound_oauth2_client_credentials_jwt!,
                :oauth2_client_credentials_setup_info

      # RFC 7235 auth-scheme comparison is case-insensitive.
      BEARER_PREFIX = /\ABearer\s+/i

      def verify_inbound_oauth2_client_credentials_jwt!(request)
        token = bearer_token_from(request)
        fail_job!('Missing or malformed Authorization header.') if token.blank?

        begin
          decoded = IPaaS::Connector::Authentication::Inbound::OAuth2ClientCredentials::Verifier
                    .verify!(token, account_id, solution.uuid, uuid)
          log_verified_token(decoded[:payload])
          decoded
        rescue IPaaS::Error => e
          fail_job!("Invalid bearer token: #{e.message}")
        end
      end

      def oauth2_client_credentials_setup_info
        base_url = IPaaS::Connector::Authentication::Inbound::OAuth2ClientCredentials::Verifier.base_url&.to_s
        return {} unless base_url.present?

        token_url = "#{base_url.chomp('/')}/oauth/token/#{account_id}/#{solution.uuid}/#{uuid}"
        {
          'OAuth 2.0 client credentials' => {
            'Token URL' => { value: token_url, copyable: true },
            'Grant type' => { value: 'client_credentials' },
          },
        }
      end

      private

      # Audit trail: `ctx` (present only on debug-minted tokens), `sub` (the
      # client_id, or `debug:<user id>` for debug tokens) and `sol_ver` (the
      # solution version whose config authenticated the mint) are unvalidated
      # context claims — log them so the job record shows which credential the
      # caller used. Any may be absent (tokens from other minters).
      def log_verified_token(payload)
        details = { 'ctx' => payload['ctx'], 'sub' => payload['sub'], 'sol_ver' => payload['sol_ver'] }
                  .compact.map { |k, v| "#{k}: #{v}" }.join(', ')
        log("Verified inbound OAuth 2.0 bearer token#{" (#{details})" if details.present?}")
      end

      def bearer_token_from(request)
        header = request.headers['Authorization']
        return nil unless header&.match?(BEARER_PREFIX)

        header.sub(BEARER_PREFIX, '').strip.presence
      end
    end
  end
end

IPaaS::Job::Context.extension(IPaaS::Job::InboundOAuth2ClientCredentials)
