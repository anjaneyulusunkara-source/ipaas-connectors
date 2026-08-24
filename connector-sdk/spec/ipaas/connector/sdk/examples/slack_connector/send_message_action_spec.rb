require 'spec_helper'

describe 'Slack Send Message', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7d7b-b2ba-d83be61d5624' }

  describe 'input_schema' do
    it 'defines required channel and text fields and optional thread_ts' do
      expect(action.input_schema.field(:channel).required).to be(true)
      expect(action.input_schema.field(:channel).type).to eq(:string)
      expect(action.input_schema.field(:text).required).to be(true)
      expect(action.input_schema.field(:text).type).to eq(:string)
      expect(action.input_schema.field(:thread_ts).visibility).to eq('optional')
      expect(action.input_schema.field(:thread_ts).type).to eq(:string)
    end
  end

  describe 'output_schema' do
    let(:output_schema) { action.output_schema.first }

    it 'defines ok, channel, ts, and message fields' do
      expect(output_schema.field(:ok).type).to eq(:boolean)
      expect(output_schema.field(:channel).type).to eq(:string)
      expect(output_schema.field(:ts).type).to eq(:string)
      expect(output_schema.field(:message).type).to eq(:hash)
    end
  end

  describe 'run' do
    let(:post_message_url) { "#{slack_api}/chat.postMessage" }
    let(:rate_limit_url) { post_message_url }
    let(:rate_limit_http_method) { :post }
    let(:rate_limit_input) { { channel: 'C123', text: 'Hello' } }

    it_behaves_like 'slack rate limiting'

    context 'when sending a message' do
      before do
        stub_request(:post, post_message_url)
          .with(body: { channel: 'C123', text: 'Hello' }.to_json,
                headers: { 'Content-Type' => 'application/json' })
          .to_return(status: 200, body: {
            ok: true, channel: 'C123', ts: '1234.5678',
            message: { text: 'Hello', user: 'U123', ts: '1234.5678', type: 'message' },
          }.to_json)
      end

      it 'sends the message and returns output' do
        output = run_action({ channel: 'C123', text: 'Hello' })
        expect(output[:ok]).to be(true)
        expect(output[:channel]).to eq('C123')
        expect(output[:ts]).to eq('1234.5678')
        expect(output[:message]).to include('text' => 'Hello')
      end
    end

    context 'when sending a threaded reply' do
      before do
        stub_request(:post, post_message_url)
          .with(body: { channel: 'C123', text: 'Reply', thread_ts: '1234.0000' }.to_json)
          .to_return(status: 200, body: { ok: true, channel: 'C123', ts: '1234.5679' }.to_json)
      end

      it 'includes thread_ts in the request' do
        output = run_action({ channel: 'C123', text: 'Reply', thread_ts: '1234.0000' })
        expect(output[:ok]).to be(true)
        expect(output[:ts]).to eq('1234.5679')
      end
    end

    context 'when API returns error' do
      before do
        stub_request(:post, post_message_url)
          .to_return(status: 200, body: { ok: false, error: 'channel_not_found' }.to_json)
      end

      it 'fails the job' do
        expect { run_action({ channel: 'C_INVALID', text: 'Hello' }) }
          .to raise_error(IPaaS::Job::FailJob, /Slack API error: channel_not_found/)
      end
    end

    context 'when API returns missing_scope' do
      before do
        stub_request(:post, post_message_url)
          .to_return(status: 200, body: {
            ok: false, error: 'missing_scope',
            needed: 'chat:write', provided: 'channels:read',
          }.to_json)
      end

      it 'surfaces needed and provided scope details' do
        expected = /Slack API error: missing_scope \(needed: chat:write, provided: channels:read\)/
        expect { run_action({ channel: 'C123', text: 'Hello' }) }
          .to raise_error(IPaaS::Job::FailJob, expected)
      end
    end
  end
end
