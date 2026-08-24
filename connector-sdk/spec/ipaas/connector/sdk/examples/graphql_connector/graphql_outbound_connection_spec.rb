require 'spec_helper'

describe 'GraphQL Outbound Connection', :outbound_connection do
  let(:connector_id) { 'd5bbb2a2-4a95-4b49-b490-56711e4455f8' }

  let(:outbound_connection_config) do
    {
      graphql_endpoint: 'https://api.example.com/graphql',
      auth_type: 'bearer_token',
      bearer_token: { token: make_secret_string('my-token') },
    }
  end

  describe 'validation' do
    it 'is valid with bearer token auth' do
      expect(outbound_connection).to be_valid, outbound_connection.full_error_messages
    end

    it 'is valid with API key header auth' do
      outbound_connection_config.merge!(
        auth_type: 'api_key_header',
        api_key_header: { header_name: 'X-API-Key', header_value: make_secret_string('key123') },
      )
      outbound_connection_config.delete(:bearer_token)
      expect(outbound_connection).to be_valid, outbound_connection.full_error_messages
    end

    it 'is valid with OAuth2 auth' do
      outbound_connection_config.merge!(
        auth_type: 'oauth2',
        oauth2: {
          token_endpoint: 'https://auth.example.com/token',
          client_id: 'my-client',
          client_secret: make_secret_string('my-secret'),
        },
      )
      outbound_connection_config.delete(:bearer_token)
      expect(outbound_connection).to be_valid, outbound_connection.full_error_messages
    end

    it 'is valid with basic auth' do
      outbound_connection_config.merge!(
        auth_type: 'basic_auth',
        basic_auth: { username: 'peter', password: make_secret_string('hunter2') },
      )
      outbound_connection_config.delete(:bearer_token)
      expect(outbound_connection).to be_valid, outbound_connection.full_error_messages
    end

    it 'is invalid with basic auth missing a password' do
      outbound_connection_config.merge!(auth_type: 'basic_auth', basic_auth: { username: 'peter' })
      outbound_connection_config.delete(:bearer_token)
      expect(outbound_connection).not_to be_valid
      expect(outbound_connection.full_error_messages).to match(/basic_auth.*password.*required/i)
    end

    it 'is invalid with basic auth missing a username' do
      outbound_connection_config.merge!(
        auth_type: 'basic_auth',
        basic_auth: { password: make_secret_string('hunter2') },
      )
      outbound_connection_config.delete(:bearer_token)
      expect(outbound_connection).not_to be_valid
      expect(outbound_connection.full_error_messages).to match(/basic_auth.*username.*required/i)
    end

    it 'is valid with no authentication' do
      outbound_connection_config[:auth_type] = 'none'
      outbound_connection_config.delete(:bearer_token)
      expect(outbound_connection).to be_valid, outbound_connection.full_error_messages
    end

    it 'is invalid without graphql_endpoint' do
      outbound_connection_config.delete(:graphql_endpoint)
      expect(outbound_connection).not_to be_valid
    end
  end

  describe 'config_schema' do
    it 'defines graphql_endpoint as a required URI' do
      field = outbound_connection.config_schema.field(:graphql_endpoint)
      expect(field.type).to eq(:uri)
      expect(field.required).to be_truthy
    end

    it 'defines auth_type as a required string with five options' do
      field = outbound_connection.config_schema.field(:auth_type)
      expect(field.type).to eq(:string)
      expect(field.required).to be_truthy
      enum_ids = field.enumeration.map { |e| e[:id] }
      expect(enum_ids).to contain_exactly('bearer_token', 'basic_auth', 'api_key_header', 'oauth2', 'none')
    end

    it 'defines basic_auth nested field' do
      basic_auth_field = outbound_connection.config_schema.field(:basic_auth)
      expect(basic_auth_field.type).to eq(:nested)
      expect(basic_auth_field.field(:username).type).to eq(:string)
      expect(basic_auth_field.field(:username).required).to be_truthy
      expect(basic_auth_field.field(:password).type).to eq(:secret_string)
      expect(basic_auth_field.field(:password).required).to be_truthy
    end

    it 'defines bearer_token nested field' do
      bearer_field = outbound_connection.config_schema.field(:bearer_token)
      expect(bearer_field.type).to eq(:nested)
      expect(bearer_field.field(:token).type).to eq(:secret_string)
      expect(bearer_field.field(:token).required).to be_truthy
    end

    it 'defines api_key_header nested field' do
      api_key_field = outbound_connection.config_schema.field(:api_key_header)
      expect(api_key_field.type).to eq(:nested)
      expect(api_key_field.field(:header_name).type).to eq(:string)
      expect(api_key_field.field(:header_name).required).to be_truthy
      expect(api_key_field.field(:header_value).type).to eq(:secret_string)
      expect(api_key_field.field(:header_value).required).to be_truthy
    end

    it 'defines oauth2 nested field' do
      oauth2_field = outbound_connection.config_schema.field(:oauth2)
      expect(oauth2_field.type).to eq(:nested)
      expect(oauth2_field.field(:token_endpoint).type).to eq(:uri)
      expect(oauth2_field.field(:token_endpoint).required).to be_truthy
      expect(oauth2_field.field(:client_id).type).to eq(:string)
      expect(oauth2_field.field(:client_id).required).to be_truthy
      expect(oauth2_field.field(:client_secret).type).to eq(:secret_string)
      expect(oauth2_field.field(:client_secret).required).to be_truthy
      expect(oauth2_field.field(:scope).type).to eq(:string)
      expect(oauth2_field.field(:scope).visibility).to eq('optional')
    end

    it 'defines schema_source field' do
      field = outbound_connection.config_schema.field(:schema_source)
      expect(field.type).to eq(:string)
      enum_ids = field.enumeration.map { |e| e[:id] }
      expect(enum_ids).to contain_exactly('introspection', 'manual')
    end

    it 'defines full_schema field' do
      field = outbound_connection.config_schema.field(:full_schema)
      expect(field.type).to eq(:string)
    end

    describe 'field visibility' do
      def resolve_with(auth_type:, schema_source: 'introspection')
        schema = outbound_connection.config_schema
        values = schema.resolve(outbound_connection, [
          { field_id: 'graphql_endpoint', fixed: 'https://api.example.com/graphql' },
          { field_id: 'auth_type', fixed: auth_type },
          { field_id: 'schema_source', fixed: schema_source },
        ])
        expect(values.base_error).to be_nil
        schema
      end

      def auth_group_ids
        outbound_connection.config_schema.field(:auth_type)
                           .enumeration.map { |option| option[:id].to_sym } - [:none]
      end

      def auth_group_visibilities(schema)
        auth_group_ids.to_h { |id| [id, schema.field(id).visibility] }
      end

      def only_visible(field_id)
        auth_group_ids.to_h { |id| [id, id == field_id ? 'visible' : 'hidden'] }
      end

      it 'reveals only the oauth2 group when auth_type is oauth2' do
        expect(auth_group_visibilities(resolve_with(auth_type: 'oauth2')))
          .to eq(only_visible(:oauth2))
      end

      it 'reveals only the bearer token group when auth_type is bearer_token' do
        expect(auth_group_visibilities(resolve_with(auth_type: 'bearer_token')))
          .to eq(only_visible(:bearer_token))
      end

      it 'reveals only the basic auth group when auth_type is basic_auth' do
        expect(auth_group_visibilities(resolve_with(auth_type: 'basic_auth')))
          .to eq(only_visible(:basic_auth))
      end

      it 'reveals only the api key group when auth_type is api_key_header' do
        expect(auth_group_visibilities(resolve_with(auth_type: 'api_key_header')))
          .to eq(only_visible(:api_key_header))
      end

      it 'hides every auth group when auth_type is none' do
        expect(auth_group_visibilities(resolve_with(auth_type: 'none')))
          .to eq(bearer_token: 'hidden', basic_auth: 'hidden',
                 api_key_header: 'hidden', oauth2: 'hidden')
      end

      it 'reveals full_schema for manual schema source without disturbing the auth rules' do
        schema = resolve_with(auth_type: 'oauth2', schema_source: 'manual')
        expect(schema.field(:full_schema).visibility).to eq('visible')
        expect(auth_group_visibilities(schema)).to eq(only_visible(:oauth2))
      end

      it 'keeps full_schema optional for introspection schema source' do
        expect(resolve_with(auth_type: 'oauth2').field(:full_schema).visibility).to eq('optional')
      end

      it 'has a field group for every auth type except none' do
        expect(auth_group_ids).to contain_exactly(:bearer_token, :basic_auth, :api_key_header, :oauth2)
        auth_group_ids.each { |id| expect(outbound_connection.config_schema.field(id)).not_to be_nil }
      end
    end

    it 'defines custom_headers array field' do
      field = outbound_connection.config_schema.field(:custom_headers)
      expect(field.type).to eq(:nested)
      expect(field.array).to be_truthy
      expect(field.visibility).to eq('optional')
      expect(field.field(:name).type).to eq(:string)
      expect(field.field(:name).required).to be_truthy
      expect(field.field(:value).type).to eq(:string)
      expect(field.field(:value).required).to be_truthy
    end
  end

  describe 'authenticate' do
    let(:request) do
      Faraday::Request.create(:get) { |req| req.headers = {} }
    end

    describe 'bearer token' do
      before { outbound_connection.authenticate_request(request) }

      it 'adds Authorization header' do
        expect(request.headers['Authorization']).to eq('Bearer my-token')
      end
    end

    describe 'API key header' do
      let(:outbound_connection_config) do
        {
          graphql_endpoint: 'https://api.example.com/graphql',
          auth_type: 'api_key_header',
          api_key_header: { header_name: 'X-API-Key', header_value: make_secret_string('key123') },
        }
      end

      before { outbound_connection.authenticate_request(request) }

      it 'adds custom API key header' do
        expect(request.headers['X-API-Key']).to eq('key123')
      end
    end

    describe 'basic auth' do
      let(:outbound_connection_config) do
        {
          graphql_endpoint: 'https://api.example.com/graphql',
          auth_type: 'basic_auth',
          basic_auth: { username: 'peter', password: make_secret_string('hunter2') },
        }
      end

      before { outbound_connection.authenticate_request(request) }

      it 'adds a base64-encoded Basic Authorization header' do
        expect(request.headers['Authorization']).to eq("Basic #{Base64.strict_encode64('peter:hunter2')}")
      end
    end

    describe 'basic auth with a colon in the password' do
      let(:outbound_connection_config) do
        {
          graphql_endpoint: 'https://api.example.com/graphql',
          auth_type: 'basic_auth',
          basic_auth: { username: 'peter', password: make_secret_string('pass:with:colons') },
        }
      end

      before { outbound_connection.authenticate_request(request) }

      it 'splits on the first colon only, per RFC 7617' do
        encoded = request.headers['Authorization'].delete_prefix('Basic ')
        expect(Base64.strict_decode64(encoded).split(':', 2)).to eq(['peter', 'pass:with:colons'])
      end
    end

    describe 'custom headers' do
      let(:outbound_connection_config) do
        {
          graphql_endpoint: 'https://api.example.com/graphql',
          auth_type: 'bearer_token',
          bearer_token: { token: make_secret_string('my-token') },
          custom_headers: [
            { name: 'X-Custom-Header', value: 'custom-value' },
            { name: 'X-Tenant-ID', value: 'tenant-123' },
          ],
        }
      end

      before { outbound_connection.authenticate_request(request) }

      it 'adds custom headers alongside auth header' do
        expect(request.headers['Authorization']).to eq('Bearer my-token')
        expect(request.headers['X-Custom-Header']).to eq('custom-value')
        expect(request.headers['X-Tenant-ID']).to eq('tenant-123')
      end
    end

    describe 'no authentication' do
      let(:outbound_connection_config) do
        {
          graphql_endpoint: 'https://api.example.com/graphql',
          auth_type: 'none',
        }
      end

      before { outbound_connection.authenticate_request(request) }

      it 'does not add Authorization header' do
        expect(request.headers['Authorization']).to be_nil
      end
    end
  end
end
