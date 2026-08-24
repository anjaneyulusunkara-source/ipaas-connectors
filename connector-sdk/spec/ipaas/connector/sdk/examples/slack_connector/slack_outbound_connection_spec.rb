require 'spec_helper'

describe 'Slack Outbound Connection', :outbound_connection do
  let(:connector_id) { '019d6e9d-90c5-724f-840b-13cb467ff342' }

  let(:outbound_connection_config) do
    {
      bearer: {
        bearer_token: make_secret_string('xoxb-test-token'),
      },
    }
  end

  describe 'authenticators' do
    it 'includes bearer authenticator' do
      expect(connector.outbound_connection.authenticators).to include(:bearer)
    end
  end

  describe 'authenticate' do
    let(:request) do
      Faraday::Request.create(:get) do |req|
        req.headers = {}
      end
    end

    before { outbound_connection.authenticate_request(request) }

    it { expect(request.headers['Authorization']).to eq('Bearer xoxb-test-token') }

    context 'with different token' do
      let(:outbound_connection_config) do
        {
          bearer: {
            bearer_token: make_secret_string('xoxb-other-token'),
          },
        }
      end

      it { expect(request.headers['Authorization']).to eq('Bearer xoxb-other-token') }
    end
  end
end
