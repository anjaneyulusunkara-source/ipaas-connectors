module IPaaS
  module Connector
    module Authentication
      module Inbound
        module OAuth2ClientCredentials
          # Shared claim contract for the OAuth2 client-credentials inbound
          # connection token. The token issuer and the verifier both build
          # their claims through these helpers so the two sides can never drift
          # on algorithm, audience, or issuer shape.
          module ConnectionToken
            ALGORITHM = 'RS256'.freeze

            # Minimum RSA modulus size accepted on both the minting and verifying
            # side, so the two can never disagree on key strength. 2048 is the
            # NIST-recommended floor; anything weaker fails configuration at boot.
            MIN_RSA_KEY_BITS = 2048

            class << self
              # `aud` uses the account, solution, and connection so a token
              # identifies one specific connection and cannot be replayed
              # across tenants.
              def audience_for(account_id, solution_uuid, connection_uuid)
                "#{account_id}/#{solution_uuid}/#{connection_uuid}"
              end

              # The externally-reachable base URL doubles as the `iss` claim;
              # issuer and verifier resolve it here so they stay in sync.
              def issuer_for(base_url)
                base_url
              end
            end
          end
        end
      end
    end
  end
end
