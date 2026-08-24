require 'spec_helper'

describe 'Slack Create Channel Action', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7348-b9bf-2954d187c1e8' }

  let(:action_input) { { name: 'new-channel' } }

  describe 'input_schema' do
    it 'defines the name field as required' do
      action.input_schema.field(:name).tap do |field|
        expect(field.label).to eq('Name')
        expect(field.type).to eq(:string)
        expect(field.required).to be_truthy
      end
    end

    it 'defines the is_private field as optional' do
      action.input_schema.field(:is_private).tap do |field|
        expect(field.label).to eq('Is private')
        expect(field.type).to eq(:boolean)
        expect(field.required).to be_falsey
      end
    end
  end

  describe 'output_schema' do
    let(:schema) { action.output_schema.first }

    it { expect(schema.field(:id).type).to eq(:string) }
    it { expect(schema.field(:name).type).to eq(:string) }
    it { expect(schema.field(:is_channel).type).to eq(:boolean) }
    it { expect(schema.field(:is_private).type).to eq(:boolean) }
    it { expect(schema.field(:creator).type).to eq(:string) }
    it { expect(schema.field(:created).type).to eq(:integer) }
  end

  describe 'run' do
    let(:create_url) { "#{slack_api}/conversations.create" }
    let(:rate_limit_url) { create_url }
    let(:rate_limit_http_method) { :post }
    let(:rate_limit_input) { action_input }

    it_behaves_like 'slack rate limiting'

    let(:channel_response) do
      {
        ok: true,
        channel: {
          id: 'C99999',
          name: 'new-channel',
          is_channel: true,
          is_private: false,
          creator: 'U1',
          created: 1_234_567_890,
        },
      }
    end

    context 'when creation is successful' do
      it 'creates a public channel and returns details' do
        stub = stub_request(:post, create_url)
               .with(body: { name: 'new-channel' }.to_json)
               .to_return(status: 200, body: channel_response.to_json)

        output = run_action

        expect(output[:id]).to eq('C99999')
        expect(output[:name]).to eq('new-channel')
        expect(output[:is_channel]).to eq(true)
        expect(output[:is_private]).to eq(false)
        expect(output[:creator]).to eq('U1')
        expect(output[:created]).to eq(1_234_567_890)
        expect(stub).to have_been_requested.once
      end

      it 'creates a private channel when is_private is true' do
        stub = stub_request(:post, create_url)
               .with(body: { name: 'secret-channel', is_private: true }.to_json)
               .to_return(status: 200, body: {
                 ok: true,
                 channel: {
                   id: 'C88888',
                   name: 'secret-channel',
                   is_channel: false,
                   is_private: true,
                   creator: 'U1',
                   created: 1_234_567_890,
                 },
               }.to_json)

        output = run_action({ name: 'secret-channel', is_private: true })

        expect(output[:id]).to eq('C88888')
        expect(output[:is_private]).to eq(true)
        expect(stub).to have_been_requested.once
      end
    end

    context 'when an error occurs' do
      it 'fails on Slack API error' do
        stub_request(:post, create_url)
          .to_return(status: 200, body: { ok: false, error: 'name_taken' }.to_json)

        expect { run_action }
          .to raise_error(IPaaS::Job::FailJob, /name_taken/)
      end

      it 'fails on HTTP error' do
        stub_request(:post, create_url)
          .to_return(status: 500, body: 'Internal Server Error')

        expect { run_action }
          .to raise_error(IPaaS::Job::FailJob, /500/)
      end
    end
  end
end
