require 'ipaas/connector/authentication/inbound/oauth2_client_credentials/connection_token'

module IPaaS
  module Connector
    module Authentication
      module Inbound
        module OAuth2ClientCredentials
          module Verifier
            class << self
              attr_accessor :base_url, :public_key_pem

              # Validate up-front so a bad PEM or missing base URL fails the
              # boot rather than the first verify.
              def configure
                yield self
                validate_configuration!
              end

              # base_url only, no key: configured? stays false so verify!
              # refuses. Holds the base URL that setup_info needs to build the
              # token URL on display-only roles.
              def configure_url_only
                @public_key_pem = nil
                yield self
                raise IPaaS::Error, 'OAuth inbound verifier: base URL is required' if @base_url.blank?
              end

              def configured?
                @public_key_pem.present? && @base_url.present?
              end

              def reset!
                @public_key_pem = nil
                @base_url = nil
              end

              # rubocop:disable Metrics/MethodLength
              def verify!(token, account_id, solution_uuid, connection_uuid)
                raise IPaaS::Error, 'OAuth inbound verifier not configured' unless configured?

                IPaaS::Job::JWT.decode_jwt!(
                  token,
                  algorithm: ConnectionToken::ALGORITHM,
                  pem: public_key_pem,
                  issuer: ConnectionToken.issuer_for(base_url),
                  audience: ConnectionToken.audience_for(account_id, solution_uuid, connection_uuid),
                  validate_iat: :never, # allow tokens issued more than MAX_IAT_DRIFT ago
                  validate_jti: :never # tokens are meant to be reused for their whole lifetime
                )
              rescue ::JWT::DecodeError => e
                raise IPaaS::Error, "Unable to decode JWT: #{e}"
              end
              # rubocop:enable Metrics/MethodLength

              private

              def validate_configuration!
                raise IPaaS::Error, 'OAuth inbound verifier: public key PEM is required' if @public_key_pem.blank?
                raise IPaaS::Error, 'OAuth inbound verifier: base URL is required' if @base_url.blank?

                validate_public_key!(OpenSSL::PKey::RSA.new(@public_key_pem))
              rescue OpenSSL::PKey::PKeyError => e
                raise IPaaS::Error, "OAuth inbound verifier: invalid public key PEM (#{e.message})"
              end

              # The connector is a public artifact and must never hold private key material,
              # so reject a private PEM explicitly; also enforce the shared key-strength floor.
              def validate_public_key!(key)
                if key.private?
                  raise IPaaS::Error,
                        'OAuth inbound verifier: PUBLIC_KEY contains a private key, not a public key'
                end
                return if key.n.num_bits >= ConnectionToken::MIN_RSA_KEY_BITS

                raise IPaaS::Error,
                      "OAuth inbound verifier: RSA key must be at least #{ConnectionToken::MIN_RSA_KEY_BITS} bits"
              end
            end
          end
        end
      end
    end
  end
end
