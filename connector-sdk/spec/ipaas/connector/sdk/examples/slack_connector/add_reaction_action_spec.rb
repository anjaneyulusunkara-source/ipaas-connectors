require 'spec_helper'

describe 'Slack Add Reaction', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7b8c-b4d5-95fddc454f24' }

  describe 'input_schema' do
    it 'defines required channel, timestamp, and name fields' do
      expect(action.input_schema.field(:channel).required).to be(true)
      expect(action.input_schema.field(:channel).type).to eq(:string)
      expect(action.input_schema.field(:timestamp).required).to be(true)
      expect(action.input_schema.field(:timestamp).type).to eq(:string)
      expect(action.input_schema.field(:name).required).to be(true)
      expect(action.input_schema.field(:name).type).to eq(:string)
    end
  end

  describe 'output_schema' do
    let(:output_schema) { action.output_schema.first }

    it 'defines ok field' do
      expect(output_schema.field(:ok).type).to eq(:boolean)
    end
  end

  describe 'run' do
    let(:reactions_url) { "#{slack_api}/reactions.add" }
    let(:rate_limit_url) { reactions_url }
    let(:rate_limit_http_method) { :post }
    let(:rate_limit_input) { { channel: 'C123', timestamp: '1234.5678', name: 'thumbsup' } }

    it_behaves_like 'slack rate limiting'

    context 'when adding a reaction' do
      before do
        stub_request(:post, reactions_url)
          .with(body: { channel: 'C123', timestamp: '1234.5678', name: 'thumbsup' }.to_json,
                headers: { 'Content-Type' => 'application/json' })
          .to_return(status: 200, body: { ok: true }.to_json)
      end

      it 'adds the reaction and returns output' do
        output = run_action({ channel: 'C123', timestamp: '1234.5678', name: 'thumbsup' })
        expect(output[:ok]).to be(true)
      end
    end

    context 'when API returns error' do
      before do
        stub_request(:post, reactions_url)
          .to_return(status: 200, body: { ok: false, error: 'already_reacted' }.to_json)
      end

      it 'fails the job' do
        expect { run_action({ channel: 'C123', timestamp: '1234.5678', name: 'thumbsup' }) }
          .to raise_error(IPaaS::Job::FailJob, /Slack API error: already_reacted/)
      end
    end
  end
end
