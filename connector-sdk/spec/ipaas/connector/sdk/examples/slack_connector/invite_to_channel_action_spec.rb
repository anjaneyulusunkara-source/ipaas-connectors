require 'spec_helper'

describe 'Slack Invite to Channel Action', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7ea5-8660-d4051ed155f5' }

  let(:action_input) { { channel: 'C12345', users: 'U111,U222' } }

  describe 'input_schema' do
    it 'defines the channel field as required' do
      action.input_schema.field(:channel).tap do |field|
        expect(field.label).to eq('Channel')
        expect(field.type).to eq(:string)
        expect(field.required).to be_truthy
      end
    end

    it 'defines the users field as required' do
      action.input_schema.field(:users).tap do |field|
        expect(field.label).to eq('Users')
        expect(field.type).to eq(:string)
        expect(field.required).to be_truthy
      end
    end
  end

  describe 'output_schema' do
    let(:schema) { action.output_schema.first }

    it { expect(schema.field(:id).type).to eq(:string) }
    it { expect(schema.field(:name).type).to eq(:string) }
  end

  describe 'run' do
    let(:invite_url) { "#{slack_api}/conversations.invite" }
    let(:rate_limit_url) { invite_url }
    let(:rate_limit_http_method) { :post }
    let(:rate_limit_input) { action_input }

    it_behaves_like 'slack rate limiting'

    context 'when invitation is successful' do
      it 'invites users and returns channel info' do
        stub = stub_request(:post, invite_url)
               .with(body: { channel: 'C12345', users: 'U111,U222' }.to_json)
               .to_return(status: 200, body: {
                 ok: true,
                 channel: { id: 'C12345', name: 'general' },
               }.to_json)

        output = run_action

        expect(output[:id]).to eq('C12345')
        expect(output[:name]).to eq('general')
        expect(stub).to have_been_requested.once
      end
    end

    context 'when an error occurs' do
      it 'fails on Slack API error' do
        stub_request(:post, invite_url)
          .to_return(status: 200, body: { ok: false, error: 'already_in_channel' }.to_json)

        expect { run_action }
          .to raise_error(IPaaS::Job::FailJob, /already_in_channel/)
      end

      it 'fails on HTTP error' do
        stub_request(:post, invite_url)
          .to_return(status: 500, body: 'Internal Server Error')

        expect { run_action }
          .to raise_error(IPaaS::Job::FailJob, /500/)
      end
    end
  end
end
