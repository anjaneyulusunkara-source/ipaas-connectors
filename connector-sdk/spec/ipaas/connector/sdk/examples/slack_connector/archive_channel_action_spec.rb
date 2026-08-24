require 'spec_helper'

describe 'Slack Archive Channel Action', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-737a-bede-4be6cf62df9a' }

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

    it { expect(schema.field(:ok).type).to eq(:boolean) }
  end

  describe 'run' do
    let(:archive_url) { "#{slack_api}/conversations.archive" }
    let(:rate_limit_url) { archive_url }
    let(:rate_limit_http_method) { :post }
    let(:rate_limit_input) { action_input }

    it_behaves_like 'slack rate limiting'

    context 'when archiving is successful' do
      it 'archives the channel and returns ok' do
        stub = stub_request(:post, archive_url)
               .with(body: { channel: 'C12345' }.to_json)
               .to_return(status: 200, body: { ok: true }.to_json)

        output = run_action

        expect(output[:ok]).to eq(true)
        expect(stub).to have_been_requested.once
      end
    end

    context 'when an error occurs' do
      it 'fails on Slack API error' do
        stub_request(:post, archive_url)
          .to_return(status: 200, body: { ok: false, error: 'already_archived' }.to_json)

        expect { run_action }
          .to raise_error(IPaaS::Job::FailJob, /already_archived/)
      end

      it 'fails on HTTP error' do
        stub_request(:post, archive_url)
          .to_return(status: 500, body: 'Internal Server Error')

        expect { run_action }
          .to raise_error(IPaaS::Job::FailJob, /500/)
      end
    end
  end
end
