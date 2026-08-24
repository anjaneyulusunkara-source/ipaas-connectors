require 'spec_helper'

describe 'Slack Find User by Email Action', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7499-b485-c8948ce8c7a4' }

  describe 'input_schema' do
    it 'defines email as a required string' do
      action.input_schema.field(:email).tap do |field|
        expect(field.type).to eq(:string)
        expect(field.required).to be_truthy
      end
    end
  end

  describe 'output_schema' do
    let(:schema) { action.output_schemas.first }

    it 'defines user output fields' do
      expect(schema.field(:id).type).to eq(:string)
      expect(schema.field(:id).required).to be_truthy
      expect(schema.field(:name).type).to eq(:string)
      expect(schema.field(:real_name).type).to eq(:string)
      expect(schema.field(:is_admin).type).to eq(:boolean)
      expect(schema.field(:is_bot).type).to eq(:boolean)
      expect(schema.field(:deleted).type).to eq(:boolean)
      expect(schema.field(:profile).type).to eq(:hash)
    end
  end

  describe 'run' do
    let(:lookup_url) { "#{slack_api}/users.lookupByEmail" }
    let(:rate_limit_url) { lookup_url }
    let(:rate_limit_http_method) { :get }
    let(:rate_limit_input) { { email: 'test@example.com' } }

    it_behaves_like 'slack rate limiting'

    it 'returns user fields for a valid email' do
      stub = stub_request(:get, lookup_url)
             .with(query: { email: 'alice@example.com' })
             .to_return(status: 200, body: {
               ok: true,
               user: {
                 id: 'U001',
                 name: 'alice',
                 real_name: 'Alice Smith',
                 is_admin: true,
                 is_bot: false,
                 deleted: false,
                 profile: { email: 'alice@example.com' },
               },
             }.to_json)

      output = run_action({ email: 'alice@example.com' })

      expect(output[:id]).to eq('U001')
      expect(output[:name]).to eq('alice')
      expect(output[:real_name]).to eq('Alice Smith')
      expect(output[:is_admin]).to eq(true)
      expect(output[:is_bot]).to eq(false)
      expect(output[:deleted]).to eq(false)
      expect(output[:profile]).to be_a(Hash)
      expect(output[:profile][:email]).to eq('alice@example.com')
      expect(stub).to have_been_requested.once
    end

    describe 'error handling' do
      it 'fails when user is not found' do
        stub_request(:get, lookup_url)
          .with(query: { email: 'nobody@example.com' })
          .to_return(status: 200, body: {
            ok: false,
            error: 'users_not_found',
          }.to_json)

        expect { run_action({ email: 'nobody@example.com' }) }.to raise_error(
          IPaaS::Job::FailJob, 'Slack API error: users_not_found'
        )
      end
    end
  end
end
