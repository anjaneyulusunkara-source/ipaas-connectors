require 'spec_helper'

describe 'Slack Get Channel Action', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7d5f-91e7-b0fc00905306' }

  let(:action_input) { { channel: 'C12345' } }

  describe 'input_schema' do
    it 'defines the channel field as required' do
      action.input_schema.field(:channel).tap do |field|
        expect(field.label).to eq('Channel')
        expect(field.type).to eq(:string)
        expect(field.required).to be_truthy
      end
    end
  end

  describe 'output_schema' do
    let(:schema) { action.output_schema.first }

    it { expect(schema.field(:id).type).to eq(:string) }
    it { expect(schema.field(:name).type).to eq(:string) }
    it { expect(schema.field(:is_channel).type).to eq(:boolean) }
    it { expect(schema.field(:is_private).type).to eq(:boolean) }
    it { expect(schema.field(:is_archived).type).to eq(:boolean) }
    it { expect(schema.field(:num_members).type).to eq(:integer) }
    it { expect(schema.field(:topic).type).to eq(:hash) }
    it { expect(schema.field(:purpose).type).to eq(:hash) }
    it { expect(schema.field(:creator).type).to eq(:string) }
    it { expect(schema.field(:created).type).to eq(:integer) }
  end

  describe 'run' do
    let(:channel_url) { "#{slack_api}/conversations.info" }
    let(:rate_limit_url) { channel_url }
    let(:rate_limit_http_method) { :get }
    let(:rate_limit_input) { action_input }

    it_behaves_like 'slack rate limiting'

    let(:channel_response) do
      {
        ok: true,
        channel: {
          id: 'C12345',
          name: 'general',
          is_channel: true,
          is_private: false,
          is_archived: false,
          num_members: 42,
          topic: { value: 'Company-wide announcements', creator: 'U1', last_set: 0 },
          purpose: { value: 'General discussion', creator: 'U1', last_set: 0 },
          creator: 'U1',
          created: 1_234_567_890,
        },
      }
    end

    context 'when retrieval is successful' do
      it 'returns channel details' do
        stub = stub_request(:get, channel_url)
               .with(query: { 'channel' => 'C12345', 'include_num_members' => 'true' })
               .to_return(status: 200, body: channel_response.to_json)

        output = run_action

        expect(output[:id]).to eq('C12345')
        expect(output[:name]).to eq('general')
        expect(output[:is_channel]).to eq(true)
        expect(output[:is_private]).to eq(false)
        expect(output[:is_archived]).to eq(false)
        expect(output[:num_members]).to eq(42)
        expect(output[:topic]).to include('value' => 'Company-wide announcements')
        expect(output[:purpose]).to include('value' => 'General discussion')
        expect(output[:creator]).to eq('U1')
        expect(output[:created]).to eq(1_234_567_890)
        expect(stub).to have_been_requested.once
      end
    end

    context 'when an error occurs' do
      it 'fails on Slack API error' do
        stub_request(:get, channel_url)
          .with(query: { 'channel' => 'C12345', 'include_num_members' => 'true' })
          .to_return(status: 200, body: { ok: false, error: 'channel_not_found' }.to_json)

        expect { run_action }
          .to raise_error(IPaaS::Job::FailJob, /channel_not_found/)
      end

      it 'fails on HTTP error' do
        stub_request(:get, channel_url)
          .with(query: { 'channel' => 'C12345', 'include_num_members' => 'true' })
          .to_return(status: 500, body: 'Internal Server Error')

        expect { run_action }
          .to raise_error(IPaaS::Job::FailJob, /500/)
      end
    end
  end
end
