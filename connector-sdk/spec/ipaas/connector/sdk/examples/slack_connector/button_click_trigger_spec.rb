require 'spec_helper'

describe 'Slack Button Click Trigger', :trigger do
  let(:connector_id) { '019d6e9d-90c5-724f-840b-13cb467ff342' }
  let(:trigger_template_id) { '019d7d4c-1758-758c-93b8-f78dbd581714' }
  let(:signing_secret) { 'test_signing_secret_abc123' }
  # Signing secret now lives on the inbound connection (shared by all Slack triggers).
  let(:inbound_connection_config) { { signing_secret: make_secret_string(signing_secret) } }
  let(:outbound_connection_config) do
    { bearer: { bearer_token: make_secret_string('xoxb-test') } }
  end

  let(:timestamp) { Time.now.to_i.to_s }

  def slack_signature(body_string)
    basestring = "v0:#{timestamp}:#{body_string}"
    "v0=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)}"
  end

  def slack_headers(body_string)
    {
      'Content-Type' => 'application/x-www-form-urlencoded',
      'X-Slack-Request-Timestamp' => timestamp,
      'X-Slack-Signature' => slack_signature(body_string),
    }
  end

  let(:block_actions_payload) do
    {
      type: 'block_actions',
      trigger_id: '123456.789',
      response_url: 'https://hooks.slack.com/actions/T123/456/response',
      team: { id: 'T123ABC456', domain: 'test-workspace' },
      user: { id: 'U123', username: 'testuser', name: 'Test User', team_id: 'T123ABC456' },
      channel: { id: 'C123', name: 'general' },
      message: { type: 'message', text: 'Click the button', ts: '1355517523.000005' },
      actions: [
        {
          action_id: 'approve_button',
          block_id: 'block_1',
          type: 'button',
          text: { type: 'plain_text', text: 'Approve' },
          value: 'approved',
          action_ts: '1355517524.000001',
        },
      ],
    }
  end

  def form_body(payload)
    URI.encode_www_form(payload: payload.to_json)
  end

  describe 'output_schema' do
    it 'has expected top-level fields' do
      schema = trigger.output_schema
      expect(schema.field(:type).type).to eq(:string)
      expect(schema.field(:trigger_id).type).to eq(:string)
      expect(schema.field(:response_url).type).to eq(:string)
      expect(schema.field(:team).type).to eq(:nested)
      expect(schema.field(:user).type).to eq(:nested)
      expect(schema.field(:actions).type).to eq(:nested)
    end

    it 'has expected team fields' do
      team_fields = trigger.output_schema.field(:team).fields
      field_ids = team_fields.map(&:id)
      expect(field_ids).to include(:id, :domain)
    end

    it 'has expected user fields' do
      user_fields = trigger.output_schema.field(:user).fields
      field_ids = user_fields.map(&:id)
      expect(field_ids).to include(:id, :username, :name, :team_id)
    end

    it 'has expected channel fields' do
      channel_fields = trigger.output_schema.field(:channel).fields
      field_ids = channel_fields.map(&:id)
      expect(field_ids).to include(:id, :name)
    end

    it 'has expected message fields' do
      message_fields = trigger.output_schema.field(:message).fields
      field_ids = message_fields.map(&:id)
      expect(field_ids).to include(:type, :text, :ts)
    end

    it 'has expected action fields' do
      action_fields = trigger.output_schema.field(:actions).fields
      field_ids = action_fields.map(&:id)
      expect(field_ids).to include(:action_id, :block_id, :type, :text, :value, :action_ts)
    end
  end

  describe 'parse' do
    context 'HMAC signature verification' do
      it 'rejects requests with no body' do
        output = post_trigger(nil, headers: slack_headers(''))
        expect(output[:error]).to eq('Request has no body')
      end

      it 'rejects requests with missing X-Slack-Request-Timestamp header' do
        body = form_body(block_actions_payload)
        output = post_trigger(body, headers: { 'X-Slack-Signature' => slack_signature(body) })
        expect(output[:error]).to eq('Missing X-Slack-Request-Timestamp header')
      end

      it 'rejects requests with missing X-Slack-Signature header' do
        body = form_body(block_actions_payload)
        output = post_trigger(body, headers: { 'X-Slack-Request-Timestamp' => timestamp })
        expect(output[:error]).to eq('Missing X-Slack-Signature header')
      end

      it 'rejects requests with invalid signature' do
        body = form_body(block_actions_payload)
        headers = {
          'X-Slack-Request-Timestamp' => timestamp,
          'X-Slack-Signature' => 'v0=invalid_signature_value_that_is_definitely_wrong_padding',
        }
        output = post_trigger(body, headers: headers)
        expect(output[:error]).to eq('Invalid request signature')
      end

      it 'rejects requests with malformed signature prefix (missing v0=)' do
        body = form_body(block_actions_payload)
        basestring = "v0:#{timestamp}:#{body}"
        raw_hmac = OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)
        headers = {
          'X-Slack-Request-Timestamp' => timestamp,
          'X-Slack-Signature' => raw_hmac,
        }
        output = post_trigger(body, headers: headers)
        expect(output[:error]).to eq('Invalid request signature')
      end

      it 'rejects requests with stale timestamp' do
        stale_timestamp = (Time.now.to_i - 361).to_s
        body = form_body(block_actions_payload)
        basestring = "v0:#{stale_timestamp}:#{body}"
        stale_signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)}"
        headers = {
          'X-Slack-Request-Timestamp' => stale_timestamp,
          'X-Slack-Signature' => stale_signature,
        }
        output = post_trigger(body, headers: headers)
        expect(output[:error]).to eq('Request timestamp is too old')
      end
    end

    context 'payload parsing' do
      it 'rejects requests with missing payload parameter' do
        body = 'other=data'
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:error]).to eq('Missing payload parameter')
      end

      it 'rejects requests with invalid JSON in payload' do
        body = 'payload=not-json'
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:error]).to start_with('Invalid JSON in payload:')
      end

      it 'rejects a JSON payload whose root is not an object' do
        body = URI.encode_www_form(payload: '[1,2,3]')
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:error]).to eq('Invalid JSON in payload: expected an object, got Array')
      end

      it 'fails cleanly when the payload parameter is duplicated' do
        # Rack returns an Array for a repeated key, so JSON.parse raises TypeError
        # rather than JSON::ParserError; without the TypeError rescue this would
        # escape as an HTTP 500 instead of a clean failure.
        body = 'payload=a&payload=b'
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:error]).to start_with('Invalid JSON in payload:')
        expect(output[:error]).to include('Array')
      end

      it 'fails cleanly (400, not 500) when the body has malformed %-encoding' do
        # With a form Content-Type the framework's query-param middleware rejects
        # the bad %-escape first, so this never reaches the parse block's own
        # InvalidParameterError rescue (defensive fallback for non-form bodies).
        # Either way the guarantee is a clean 400 rather than an HTTP 500.
        body = 'payload=%zz'
        uri = build_trigger_uri({})
        response = Faraday.post(uri) { |req| configure_trigger_request(req, body, slack_headers(body), nil) }
        expect(response.status).to eq(400)
        expect(response.body).to include('invalid %-encoding')
      end

      it 'discards payloads with unsupported interaction type' do
        payload = block_actions_payload.merge(type: 'view_submission')
        body = form_body(payload)
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:result]).to eq('Discarded')
      end
    end

    context 'block_actions' do
      it 'parses valid block_actions payload and sets job_context_identifier from team' do
        expect(runbook).to receive(:store_job_context_identifier).with('T123ABC456')
        body = form_body(block_actions_payload)
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:error]).to be_nil
        expect(output[:type]).to eq('block_actions')
        expect(output[:trigger_id]).to eq('123456.789')
        expect(output[:response_url]).to eq('https://hooks.slack.com/actions/T123/456/response')
        expect(output[:team][:id]).to eq('T123ABC456')
        expect(output[:team][:domain]).to eq('test-workspace')
        expect(output[:user][:id]).to eq('U123')
        expect(output[:user][:username]).to eq('testuser')
        expect(output[:channel][:id]).to eq('C123')
        expect(output[:channel][:name]).to eq('general')
        expect(output[:message][:text]).to eq('Click the button')
        expect(output[:actions].first[:action_id]).to eq('approve_button')
        expect(output[:actions].first[:type]).to eq('button')
        expect(output[:actions].first[:value]).to eq('approved')
      end

      it 'falls back to user.team_id for job_context_identifier when team is absent' do
        payload = block_actions_payload.except(:team).deep_merge(user: { team_id: 'T_FALLBACK' })
        expect(runbook).to receive(:store_job_context_identifier).with('T_FALLBACK')
        body = form_body(payload)
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:error]).to be_nil
      end

      it 'handles payload without optional channel field' do
        payload = block_actions_payload.except(:channel)
        body = form_body(payload)
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:error]).to be_nil
        expect(output[:type]).to eq('block_actions')
        expect(output[:channel]).to be_nil
      end

      it 'handles payload without optional message field' do
        payload = block_actions_payload.except(:message)
        body = form_body(payload)
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:error]).to be_nil
        expect(output[:type]).to eq('block_actions')
        expect(output[:message]).to be_nil
      end

      it 'handles payload with multiple actions' do
        payload = block_actions_payload.merge(
          actions: [
            { action_id: 'btn_1', block_id: 'b1', type: 'button', value: 'v1', action_ts: '1.0' },
            { action_id: 'btn_2', block_id: 'b2', type: 'button', value: 'v2', action_ts: '2.0' },
          ],
        )
        body = form_body(payload)
        output = post_trigger(body, headers: slack_headers(body))
        expect(output[:error]).to be_nil
        expect(output[:actions].length).to eq(2)
        expect(output[:actions][0][:action_id]).to eq('btn_1')
        expect(output[:actions][1][:action_id]).to eq('btn_2')
      end
    end
  end
end
