require 'spec_helper'

describe 'Slack Delete Message', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7720-81f6-a7990830719b' }

  describe 'input_schema' do
    it 'defines required channel and ts fields' do
      expect(action.input_schema.field(:channel).required).to be(true)
      expect(action.input_schema.field(:channel).type).to eq(:string)
      expect(action.input_schema.field(:ts).required).to be(true)
      expect(action.input_schema.field(:ts).type).to eq(:string)
    end
  end

  describe 'output_schema' do
    let(:output_schema) { action.output_schema.first }

    it 'defines ok, channel, and ts fields' do
      expect(output_schema.field(:ok).type).to eq(:boolean)
      expect(output_schema.field(:channel).type).to eq(:string)
      expect(output_schema.field(:ts).type).to eq(:string)
    end
  end

  describe 'run' do
    let(:delete_url) { "#{slack_api}/chat.delete" }
    let(:rate_limit_url) { delete_url }
    let(:rate_limit_http_method) { :post }
    let(:rate_limit_input) { { channel: 'C123', ts: '1234.5678' } }

    it_behaves_like 'slack rate limiting'

    context 'when deleting a message' do
      before do
        stub_request(:post, delete_url)
          .with(body: { channel: 'C123', ts: '1234.5678' }.to_json,
                headers: { 'Content-Type' => 'application/json' })
          .to_return(status: 200, body: {
            ok: true, channel: 'C123', ts: '1234.5678',
          }.to_json)
      end

      it 'deletes the message and returns output' do
        output = run_action({ channel: 'C123', ts: '1234.5678' })
        expect(output[:ok]).to be(true)
        expect(output[:channel]).to eq('C123')
        expect(output[:ts]).to eq('1234.5678')
      end
    end

    context 'when API returns error' do
      before do
        stub_request(:post, delete_url)
          .to_return(status: 200, body: { ok: false, error: 'channel_not_found' }.to_json)
      end

      it 'fails the job' do
        expect { run_action({ channel: 'C_INVALID', ts: '1234.5678' }) }
          .to raise_error(IPaaS::Job::FailJob, /Slack API error: channel_not_found/)
      end
    end
  end
end
