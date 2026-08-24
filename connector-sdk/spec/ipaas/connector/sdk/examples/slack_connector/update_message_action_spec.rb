require 'spec_helper'

describe 'Slack Update Message', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7de8-a9cd-32f207fa8a5e' }

  describe 'input_schema' do
    it 'defines required channel, ts, and text fields' do
      expect(action.input_schema.field(:channel).required).to be(true)
      expect(action.input_schema.field(:channel).type).to eq(:string)
      expect(action.input_schema.field(:ts).required).to be(true)
      expect(action.input_schema.field(:ts).type).to eq(:string)
      expect(action.input_schema.field(:text).required).to be(true)
      expect(action.input_schema.field(:text).type).to eq(:string)
    end
  end

  describe 'output_schema' do
    let(:output_schema) { action.output_schema.first }

    it 'defines ok, channel, ts, text, and message fields' do
      expect(output_schema.field(:ok).type).to eq(:boolean)
      expect(output_schema.field(:channel).type).to eq(:string)
      expect(output_schema.field(:ts).type).to eq(:string)
      expect(output_schema.field(:text).type).to eq(:string)
      expect(output_schema.field(:message).type).to eq(:hash)
    end
  end

  describe 'run' do
    let(:update_url) { "#{slack_api}/chat.update" }
    let(:rate_limit_url) { update_url }
    let(:rate_limit_http_method) { :post }
    let(:rate_limit_input) { { channel: 'C123', ts: '1234.5678', text: 'Updated' } }

    it_behaves_like 'slack rate limiting'

    context 'when updating a message' do
      before do
        stub_request(:post, update_url)
          .with(body: { channel: 'C123', ts: '1234.5678', text: 'Updated' }.to_json,
                headers: { 'Content-Type' => 'application/json' })
          .to_return(status: 200, body: {
            ok: true, channel: 'C123', ts: '1234.5678', text: 'Updated',
            message: { type: 'message', user: 'U123', text: 'Updated', ts: '1234.5678' },
          }.to_json)
      end

      it 'updates the message and returns output' do
        output = run_action({ channel: 'C123', ts: '1234.5678', text: 'Updated' })
        expect(output[:ok]).to be(true)
        expect(output[:channel]).to eq('C123')
        expect(output[:ts]).to eq('1234.5678')
        expect(output[:text]).to eq('Updated')
        expect(output[:message]).to include('user' => 'U123', 'text' => 'Updated')
      end
    end

    context 'when API returns error' do
      before do
        stub_request(:post, update_url)
          .to_return(status: 200, body: { ok: false, error: 'message_not_found' }.to_json)
      end

      it 'fails the job' do
        expect { run_action({ channel: 'C123', ts: '0000.0000', text: 'Updated' }) }
          .to raise_error(IPaaS::Job::FailJob, /Slack API error: message_not_found/)
      end
    end
  end
end
