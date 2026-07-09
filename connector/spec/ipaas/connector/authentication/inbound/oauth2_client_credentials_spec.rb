require 'spec_helper'

describe IPaaS::Connector::Authentication::Inbound::OAuth2ClientCredentials do
  let(:connector) do
    IPaaS::Connector::Connector.new('uuid') do
      inbound_connection do
        oauth2_client_credentials_validator
      end
    end
  end

  it 'registers the key' do
    expect(IPaaS::Connector::Authentication::Inbound.keys).to include(:oauth2_client_credentials)
  end

  describe 'schema' do
    let(:field) { connector.inbound_connection.config_schema.field(:oauth2_client_credentials) }

    it 'defines the nested field with client_id, client_secret, token_ttl_seconds' do
      expect(field.label).to eq('OAuth 2.0 client credentials')
      expect(field.visibility).to eq('optional')
      expect(field.field(:client_id).type).to eq(:string)
      expect(field.field(:client_secret).type).to eq(:hashed_credential)
      expect(field.field(:token_ttl_seconds).type).to eq(:integer)
    end
  end
end
