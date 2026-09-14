require 'spec_helper'

describe 'Jamf Connection', :outbound_connection do
  let(:connector_id) { '019ff02c-617b-7f56-9117-462ffc1b5cba' }

  let(:outbound_connection_config) do
    {
      credentials: {
        jamf_url: 'https://acme.jamfcloud.com',
        client_id: 'abc',
        client_secret: make_secret_string('def'),
      },
    }
  end

  describe 'config_schema' do
    it 'requires the Jamf Pro URL' do
      outbound_connection_config[:credentials].delete(:jamf_url)
      expect(outbound_connection).not_to be_valid, outbound_connection.full_error_messages
    end

    it 'requires the client ID' do
      outbound_connection_config[:credentials].delete(:client_id)
      expect(outbound_connection).not_to be_valid, outbound_connection.full_error_messages
    end

    it 'requires the client secret' do
      outbound_connection_config[:credentials].delete(:client_secret)
      expect(outbound_connection).not_to be_valid, outbound_connection.full_error_messages
    end

    it 'is valid with all three credentials' do
      expect(outbound_connection).to be_valid, outbound_connection.full_error_messages
    end

    it 'defines the Jamf Pro URL field as a URI' do
      outbound_connection.config_schema.field(:credentials).field(:jamf_url).tap do |field|
        expect(field.label).to eq('Jamf Pro URL')
        expect(field.type).to eq(:uri)
        expect(field.required).to be_truthy
      end
    end

    it 'defines the client secret as a secret string' do
      outbound_connection.config_schema.field(:credentials).field(:client_secret).tap do |field|
        expect(field.label).to eq('Client secret')
        expect(field.type).to eq(:secret_string)
        expect(field.required).to be_truthy
      end
    end
  end

  describe 'authenticate' do
    let(:request) do
      Faraday::Request.create(:get) { |req| req.headers = {} }
    end

    let(:token_url) { 'https://acme.jamfcloud.com/api/v1/oauth/token' }

    def stub_token(url: token_url, status: 200, body: nil)
      body ||= { access_token: 'jamf-token', token_type: 'Bearer', scope: 'api-role:1', expires_in: 1799 }
      stub_request(:post, url)
        .with(body: {
                client_id: 'abc',
                client_secret: 'def',
                grant_type: 'client_credentials',
              },
              headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
        .to_return(status: status, body: body.to_json)
    end

    it 'sets the bearer header from the client credentials grant' do
      stub_token
      outbound_connection.authenticate_request(request)
      expect(request.headers['Authorization']).to eq('Bearer jamf-token')
    end

    it 'asks for JSON' do
      stub_token
      outbound_connection.authenticate_request(request)
      expect(request.headers['Accept']).to eq('application/json')
    end

    it 'raises a customer credentials error when Jamf rejects the secret' do
      stub_token(status: 401, body: { error: 'invalid_client' })
      expect { outbound_connection.authenticate_request(request) }
        .to raise_error(IPaaS::Job::Outbound::CustomerCredentialsError, /invalid_client/)
    end

    describe 'URL normalization' do
      def token_url_for(jamf_url)
        outbound_connection_config[:credentials][:jamf_url] = jamf_url
        stub = stub_token(url: 'https://acme.jamfcloud.com/api/v1/oauth/token')
        outbound_connection.authenticate_request(request)
        expect(stub).to have_been_requested
      end

      it 'accepts a URL with no trailing slash' do
        token_url_for('https://acme.jamfcloud.com')
      end

      it 'strips a single trailing slash' do
        token_url_for('https://acme.jamfcloud.com/')
      end

      it 'strips several trailing slashes' do
        token_url_for('https://acme.jamfcloud.com///')
      end

      it 'strips an /api the customer pasted in' do
        token_url_for('https://acme.jamfcloud.com/api')
      end

      it 'strips a trailing /api/ with its slash' do
        token_url_for('https://acme.jamfcloud.com/api/')
      end

      it 'strips surrounding whitespace' do
        token_url_for('  https://acme.jamfcloud.com  ')
      end

      it 'fails when the URL has no https scheme' do
        outbound_connection_config[:credentials][:jamf_url] = 'acme.jamfcloud.com'
        expect { outbound_connection.authenticate_request(request) }
          .to raise_error(IPaaS::Job::FailJob, %r{must start with https://})
      end
    end
  end

  describe 'config_tester' do
    let(:version_url) { 'https://acme.jamfcloud.com/api/v1/jamf-pro-version' }

    before(:each) do
      stub_request(:post, 'https://acme.jamfcloud.com/api/v1/oauth/token')
        .to_return(status: 200, body: { access_token: 'jamf-token', token_type: 'Bearer' }.to_json)
    end

    it 'provides the config_tester feature' do
      expect(outbound_connection.config_tester?).to be true
    end

    it 'reports the Jamf Pro version on success' do
      stub_request(:get, version_url).to_return(status: 200, body: { version: '11.30.2-t1785446884863' }.to_json)
      expect(outbound_connection.config_tester)
        .to eq({ status: :success, message: 'Connection successful. Jamf Pro version 11.30.2-t1785446884863.' })
    end

    it 'reports failed when Jamf rejects the token' do
      stub_request(:get, version_url).to_return(status: 401, body: { httpStatus: 401, errors: [] }.to_json)
      expect(outbound_connection.config_tester)
        .to eq({ status: :failed, message: 'Jamf rejected the credentials (HTTP 401).' })
    end

    it 'reports error on an unexpected status' do
      stub_request(:get, version_url).to_return(status: 500, body: 'boom')
      expect(outbound_connection.config_tester[:status]).to eq(:error)
    end

    it 'reports error before calling Jamf when the URL has no scheme' do
      outbound_connection_config[:credentials][:jamf_url] = 'acme.jamfcloud.com'
      expect(outbound_connection.config_tester)
        .to eq({ status: :error, message: 'Connection configuration is invalid.' })
      expect(a_request(:get, version_url)).not_to have_been_requested
    end

    # Contrast with the schemeless case above: the :uri field type accepts http, so the
    # https guard in api_base is the only thing that rejects a plaintext Jamf URL.
    it 'reports error for an http URL that passes schema validation' do
      outbound_connection_config[:credentials][:jamf_url] = 'http://acme.jamfcloud.com'
      expect(outbound_connection).to be_valid, outbound_connection.full_error_messages
      expect(outbound_connection.config_tester[:message]).to match(%r{must start with https://})
    end
  end
end
