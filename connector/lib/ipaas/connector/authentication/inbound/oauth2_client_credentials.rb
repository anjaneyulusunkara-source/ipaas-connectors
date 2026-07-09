module IPaaS
  module Connector
    module Authentication
      module Inbound
        # OAuth 2.0 Client Credentials inbound authentication. Verifies an
        # incoming bearer JWT cheaply — pure-CPU: signature + claim checks
        module OAuth2ClientCredentials
          include IPaaS::Connector::Schema::Extension
          include IPaaS::Connector::Authentication::Inbound::Extension

          schema do
            field :oauth2_client_credentials, 'OAuth 2.0 client credentials', :nested,
                  hint: 'Fill out these details to verify the inbound request. ' \
                        'Callers exchange the client_id/client_secret at the token URL ' \
                        '(shown after saving) for a short-lived bearer.',
                  visibility: 'optional' do
              field :client_id, 'Client ID', :string,
                    required: true
              field :client_secret, 'Client secret', :hashed_credential,
                    required: true
              field :token_ttl_seconds, 'Token TTL (seconds)', :integer,
                    required: false,
                    visibility: 'optional',
                    min: 60, # 1 minute
                    max: 86_400 # 1 day
            end
          end

          validate do |request|
            oauth_config = config[:oauth2_client_credentials]
            next if oauth_config.blank?

            verify_inbound_oauth2_client_credentials_jwt!(request)
          end

          setup_info do
            oauth_config = config[:oauth2_client_credentials]
            next nil if oauth_config.blank?

            oauth2_client_credentials_setup_info
          end
        end

        register(:oauth2_client_credentials, OAuth2ClientCredentials)
      end
    end
  end
end
