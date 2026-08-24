require 'spec_helper'

describe 'Slack Inbound Connection', :trigger do
  let(:connector_id) { '019d6e9d-90c5-724f-840b-13cb467ff342' }
  # HMAC verification is exercised through the Events trigger endpoint, but the
  # verification itself lives on the inbound connection's validate block.
  let(:trigger_template_id) { '019d6e9d-90c5-795f-aac7-2b8c69f5b32a' }
  let(:signing_secret) { 'test_signing_secret_abc123' }
  let(:inbound_connection_config) { { signing_secret: make_secret_string(signing_secret) } }
  let(:outbound_connection_config) do
    { bearer: { bearer_token: make_secret_string('xoxb-test') } }
  end
  let(:timestamp) { Time.now.to_i.to_s }

  let(:payload) do
    {
      type: 'event_callback', team_id: 'T123', api_app_id: 'A1',
      event_id: 'Ev1', event_time: 0,
      event: {
        type: 'message', channel: 'C1', user: 'U1', text: 'hi',
        ts: '1', event_ts: '1', channel_type: 'channel',
      },
    }
  end

  def signed_headers(body_string, stamp: timestamp, secret: signing_secret)
    {
      'X-Slack-Request-Timestamp' => stamp,
      'X-Slack-Signature' => "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{stamp}:#{body_string}")}",
    }
  end

  describe 'config_schema' do
    it 'requires signing_secret as a secret_string on the connection' do
      field = connector.inbound_connection.config_schema.field(:signing_secret)
      expect(field.type).to eq(:secret_string)
      expect(field.required).to be_truthy
    end
  end

  describe 'validate (HMAC verification)' do
    it 'accepts a correctly signed request' do
      output = post_trigger(payload, headers: signed_headers(payload.to_json))
      expect(output[:error]).to be_nil
    end

    it 'rejects an invalid signature' do
      headers = { 'X-Slack-Request-Timestamp' => timestamp, 'X-Slack-Signature' => 'v0=deadbeef' }
      output = post_trigger(payload, headers: headers)
      expect(output[:error]).to eq('Invalid request signature')
    end

    it 'rejects a request signed with the wrong secret' do
      output = post_trigger(payload, headers: signed_headers(payload.to_json, secret: 'wrong_secret'))
      expect(output[:error]).to eq('Invalid request signature')
    end

    it 'rejects a missing timestamp header' do
      headers = signed_headers(payload.to_json).except('X-Slack-Request-Timestamp')
      output = post_trigger(payload, headers: headers)
      expect(output[:error]).to eq('Missing X-Slack-Request-Timestamp header')
    end

    it 'rejects a missing signature header' do
      output = post_trigger(payload, headers: { 'X-Slack-Request-Timestamp' => timestamp })
      expect(output[:error]).to eq('Missing X-Slack-Signature header')
    end

    it 'rejects a stale request (replay protection)' do
      old = (Time.now.to_i - 600).to_s
      output = post_trigger(payload, headers: signed_headers(payload.to_json, stamp: old))
      expect(output[:error]).to eq('Request timestamp is too old')
    end
  end
end
