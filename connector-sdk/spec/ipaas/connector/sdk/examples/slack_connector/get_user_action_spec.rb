require 'spec_helper'

describe 'Slack Get User Action', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-70f0-8fd6-24a0c91bcb00' }

  describe 'input_schema' do
    it 'defines user as a required string' do
      action.input_schema.field(:user).tap do |field|
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
      expect(schema.field(:is_restricted).type).to eq(:boolean)
      expect(schema.field(:deleted).type).to eq(:boolean)
      expect(schema.field(:profile).type).to eq(:hash)
    end
  end

  describe 'run' do
    let(:users_info_url) { "#{slack_api}/users.info" }
    let(:rate_limit_url) { users_info_url }
    let(:rate_limit_http_method) { :get }
    let(:rate_limit_input) { { user: 'U123' } }

    it_behaves_like 'slack rate limiting'

    it 'returns user fields' do
      stub = stub_request(:get, users_info_url)
             .with(query: { user: 'U12345' })
             .to_return(status: 200, body: {
               ok: true,
               user: {
                 id: 'U12345',
                 name: 'jdoe',
                 real_name: 'John Doe',
                 is_admin: false,
                 is_bot: false,
                 is_restricted: false,
                 deleted: false,
                 profile: { email: 'jdoe@example.com', display_name: 'John' },
               },
             }.to_json)

      output = run_action({ user: 'U12345' })

      expect(output[:id]).to eq('U12345')
      expect(output[:name]).to eq('jdoe')
      expect(output[:real_name]).to eq('John Doe')
      expect(output[:is_admin]).to eq(false)
      expect(output[:is_bot]).to eq(false)
      expect(output[:is_restricted]).to eq(false)
      expect(output[:deleted]).to eq(false)
      expect(output[:profile]).to be_a(Hash)
      expect(output[:profile][:email]).to eq('jdoe@example.com')
      expect(stub).to have_been_requested.once
    end

    describe 'error handling' do
      it 'fails on Slack API error' do
        stub_request(:get, users_info_url)
          .with(query: { user: 'U99999' })
          .to_return(status: 200, body: {
            ok: false,
            error: 'user_not_found',
          }.to_json)

        expect { run_action({ user: 'U99999' }) }.to raise_error(
          IPaaS::Job::FailJob, 'Slack API error: user_not_found'
        )
      end
    end
  end
end
