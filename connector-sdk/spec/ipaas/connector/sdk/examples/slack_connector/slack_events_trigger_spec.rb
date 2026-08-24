require 'spec_helper'

describe 'Slack Events Trigger', :trigger do
  let(:connector_id) { '019d6e9d-90c5-724f-840b-13cb467ff342' }
  let(:trigger_template_id) { '019d6e9d-90c5-795f-aac7-2b8c69f5b32a' }
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
      'X-Slack-Request-Timestamp' => timestamp,
      'X-Slack-Signature' => slack_signature(body_string),
    }
  end

  describe 'output_schema' do
    it 'has expected top-level fields' do
      schema = trigger.output_schema
      expect(schema.field(:type).type).to eq(:string)
      expect(schema.field(:team_id).type).to eq(:string)
      expect(schema.field(:event_id).type).to eq(:string)
      expect(schema.field(:event_time).type).to eq(:integer)
      expect(schema.field(:event).type).to eq(:nested)
    end

    it 'has expected nested event fields' do
      event_fields = trigger.output_schema.field(:event).fields
      field_ids = event_fields.map(&:id)
      expect(field_ids).to include(:type, :channel, :user, :text, :ts, :event_ts, :channel_type)
    end
  end

  describe 'parse' do
    let(:event_callback_payload) do
      {
        type: 'event_callback',
        team_id: 'T123ABC456',
        api_app_id: 'A123ABC456',
        event: {
          type: 'message',
          channel: 'C123',
          user: 'U123',
          text: 'hello',
          ts: '1355517523.000005',
          event_ts: '1355517523.000005',
          channel_type: 'channel',
        },
        event_id: 'Ev123ABC456',
        event_time: 1_355_517_523,
      }
    end

    context 'HMAC signature verification' do
      it 'rejects requests with no body' do
        output = post_trigger(nil, headers: slack_headers(''))
        expect(output[:error]).to eq('Request has no body')
      end

      it 'rejects requests with missing X-Slack-Request-Timestamp header' do
        payload = event_callback_payload
        body_string = payload.to_json
        output = post_trigger(payload, headers: { 'X-Slack-Signature' => slack_signature(body_string) })
        expect(output[:error]).to eq('Missing X-Slack-Request-Timestamp header')
      end

      it 'rejects requests with missing X-Slack-Signature header' do
        payload = event_callback_payload
        output = post_trigger(payload, headers: { 'X-Slack-Request-Timestamp' => timestamp })
        expect(output[:error]).to eq('Missing X-Slack-Signature header')
      end

      it 'rejects requests with invalid signature' do
        payload = event_callback_payload
        headers = {
          'X-Slack-Request-Timestamp' => timestamp,
          'X-Slack-Signature' => 'v0=invalid_signature_value_that_is_definitely_wrong_padding',
        }
        output = post_trigger(payload, headers: headers)
        expect(output[:error]).to eq('Invalid request signature')
      end

      it 'rejects requests with malformed signature prefix (missing v0=)' do
        payload = event_callback_payload
        body_string = payload.to_json
        basestring = "v0:#{timestamp}:#{body_string}"
        raw_hmac = OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)
        headers = {
          'X-Slack-Request-Timestamp' => timestamp,
          'X-Slack-Signature' => raw_hmac,
        }
        output = post_trigger(payload, headers: headers)
        expect(output[:error]).to eq('Invalid request signature')
      end

      it 'rejects requests with stale timestamp' do
        stale_timestamp = (Time.now.to_i - 361).to_s
        payload = event_callback_payload
        body_string = payload.to_json
        basestring = "v0:#{stale_timestamp}:#{body_string}"
        stale_signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)}"
        headers = {
          'X-Slack-Request-Timestamp' => stale_timestamp,
          'X-Slack-Signature' => stale_signature,
        }
        output = post_trigger(payload, headers: headers)
        expect(output[:error]).to eq('Request timestamp is too old')
      end

      it 'accepts request exactly at the 5-minute boundary' do
        Timecop.freeze do
          boundary_timestamp = (Time.now.to_i - 300).to_s
          payload = event_callback_payload
          body_string = payload.to_json
          basestring = "v0:#{boundary_timestamp}:#{body_string}"
          boundary_signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)}"
          headers = {
            'X-Slack-Request-Timestamp' => boundary_timestamp,
            'X-Slack-Signature' => boundary_signature,
          }
          output = post_trigger(payload, headers: headers)
          expect(output[:error]).to be_nil
          expect(output[:type]).to eq('event_callback')
        end
      end

      it 'rejects request just past the 5-minute boundary' do
        Timecop.freeze do
          past_boundary_timestamp = (Time.now.to_i - 301).to_s
          payload = event_callback_payload
          body_string = payload.to_json
          basestring = "v0:#{past_boundary_timestamp}:#{body_string}"
          past_boundary_signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)}"
          headers = {
            'X-Slack-Request-Timestamp' => past_boundary_timestamp,
            'X-Slack-Signature' => past_boundary_signature,
          }
          output = post_trigger(payload, headers: headers)
          expect(output[:error]).to eq('Request timestamp is too old')
        end
      end

      it 'accepts a request at the future clock-skew boundary' do
        Timecop.freeze do
          # 60s in the future is exactly the allowed skew (age == -60, not < -60).
          skew_timestamp = (Time.now.to_i + 60).to_s
          payload = event_callback_payload
          body_string = payload.to_json
          basestring = "v0:#{skew_timestamp}:#{body_string}"
          skew_signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)}"
          headers = {
            'X-Slack-Request-Timestamp' => skew_timestamp,
            'X-Slack-Signature' => skew_signature,
          }
          output = post_trigger(payload, headers: headers)
          expect(output[:error]).to be_nil
          expect(output[:type]).to eq('event_callback')
        end
      end

      it 'rejects a request past the future clock-skew boundary' do
        Timecop.freeze do
          future_timestamp = (Time.now.to_i + 61).to_s
          payload = event_callback_payload
          body_string = payload.to_json
          basestring = "v0:#{future_timestamp}:#{body_string}"
          future_signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)}"
          headers = {
            'X-Slack-Request-Timestamp' => future_timestamp,
            'X-Slack-Signature' => future_signature,
          }
          output = post_trigger(payload, headers: headers)
          expect(output[:error]).to eq('Request timestamp is in the future')
        end
      end

      it 'rejects request with non-numeric timestamp' do
        non_numeric_timestamp = 'not-a-number'
        payload = event_callback_payload
        body_string = payload.to_json
        basestring = "v0:#{non_numeric_timestamp}:#{body_string}"
        non_numeric_signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)}"
        headers = {
          'X-Slack-Request-Timestamp' => non_numeric_timestamp,
          'X-Slack-Signature' => non_numeric_signature,
        }
        output = post_trigger(payload, headers: headers)
        expect(output[:error]).to eq('Invalid X-Slack-Request-Timestamp header')
      end

      it 'accepts requests with valid signature' do
        payload = event_callback_payload
        output = post_trigger(payload, headers: slack_headers(payload.to_json))
        expect(output[:error]).to be_nil
        expect(output[:type]).to eq('event_callback')
      end
    end

    context 'URL verification challenge' do
      # The parse ↔ respond_with challenge contract (that respond_with echoes the
      # value parse captured) is pinned in the 'respond_with' describe block below;
      # here we only cover the parse-side discard and the missing-challenge failure.
      it 'returns discarded result with challenge response' do
        payload = { type: 'url_verification', token: 'abc', challenge: 'test_challenge_string' }
        output = post_trigger(payload, headers: slack_headers(payload.to_json))
        expect(output[:result]).to eq('Discarded')
      end

      it 'fails the job when the challenge is missing' do
        payload = { type: 'url_verification', token: 'abc' }
        output = post_trigger(payload, headers: slack_headers(payload.to_json))
        expect(output[:error]).to eq('Missing challenge in url_verification request')
      end
    end

    context 'event_callback' do
      it 'parses valid event_callback payload and sets job_context_identifier' do
        expect(runbook).to receive(:store_job_context_identifier).with('T123ABC456')
        payload = event_callback_payload
        output = post_trigger(payload, headers: slack_headers(payload.to_json))
        expect(output[:type]).to eq('event_callback')
        expect(output[:team_id]).to eq('T123ABC456')
        expect(output[:api_app_id]).to eq('A123ABC456')
        expect(output[:event_id]).to eq('Ev123ABC456')
        expect(output[:event_time]).to eq(1_355_517_523)
        expect(output[:event][:type]).to eq('message')
        expect(output[:event][:channel]).to eq('C123')
        expect(output[:event][:user]).to eq('U123')
        expect(output[:event][:text]).to eq('hello')
      end
    end

    context 'Slack lifecycle event types' do
      it 'discards app_rate_limited without failing the job' do
        payload = { type: 'app_rate_limited', team_id: 'T123', minute_rate_limited: 1_355_517_600 }
        output = post_trigger(payload, headers: slack_headers(payload.to_json))
        expect(output[:result]).to eq('Discarded')
      end

      it 'discards tokens_revoked without failing the job' do
        payload = { type: 'tokens_revoked', team_id: 'T123' }
        output = post_trigger(payload, headers: slack_headers(payload.to_json))
        expect(output[:result]).to eq('Discarded')
      end

      it 'discards unknown lifecycle event types' do
        payload = { type: 'unknown_type', team_id: 'T123' }
        output = post_trigger(payload, headers: slack_headers(payload.to_json))
        expect(output[:result]).to eq('Discarded')
      end
    end
  end

  describe 'respond_with' do
    before do
      allow(runbook).to receive(:trigger_output).and_return({})
    end

    it 'returns challenge JSON for URL verification (DiscardTriggerEvent)' do
      error = IPaaS::Job::DiscardTriggerEvent.new('url_verification:test_challenge_string')
      request = double
      default_headers = {}

      result = trigger.respond_with(request, nil, default_headers, { error: error })
      expect(result[:status]).to eq(200)
      expect(result[:headers]['content-type']).to eq('application/json')
      expect(JSON.parse(result[:body])).to eq({ 'challenge' => 'test_challenge_string' })
    end

    # Contract test: feed parse's actual DiscardTriggerEvent into respond_with,
    # rather than hand-building the 'url_verification:' encoding on the assert
    # side. This pins the encode/decode contract so a prefix change in one block
    # without the other fails here (the SDK harness discards before respond_with
    # runs, so post_trigger alone never exercises the echo end-to-end). The
    # colon-heavy challenge also proves respond_with slices by prefix length
    # rather than splitting on ':'.
    it 'echoes the exact challenge that parse captured (parse ↔ respond_with contract)' do
      challenge = 'challenge::with:colons_9f8a'
      body = { type: 'url_verification', token: 'abc', challenge: challenge }.to_json
      request = double(body: StringIO.new(body))

      captured_error = nil
      begin
        trigger_template.call_function(:parse, trigger, request)
      rescue IPaaS::Job::DiscardTriggerEvent => e
        captured_error = e
      end
      expect(captured_error).not_to be_nil

      result = trigger.respond_with(request, nil, {}, { error: captured_error })
      expect(result[:status]).to eq(200)
      expect(JSON.parse(result[:body])).to eq({ 'challenge' => challenge })
    end

    it 'does not echo a challenge for non-url_verification discards' do
      error = IPaaS::Job::DiscardTriggerEvent.new('Ignoring Slack request type: app_rate_limited')
      request = double
      default_headers = {}

      result = trigger.respond_with(request, nil, default_headers, { error: error })
      expect(result[:status]).to eq(200)
      expect(result[:body]).not_to include('challenge')
    end

    it 'returns default response when no error' do
      job = double(uuid: 'job-uuid-123')
      request = double
      default_headers = {}

      result = trigger.respond_with(request, job, default_headers)
      expect(result[:status]).to eq(200)
    end
  end
end
