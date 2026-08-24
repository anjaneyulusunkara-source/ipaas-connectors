require 'spec_helper'

describe 'Slack List Users Action', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7ed3-91db-fec755207870' }

  describe 'input_schema' do
    it 'defines limit as an optional integer with default 200' do
      action.input_schema.field(:limit).tap do |field|
        expect(field.type).to eq(:integer)
        expect(field.required).to be_falsey
        expect(field.visibility).to eq('optional')
        expect(field.default).to eq(200)
        expect(field.min).to eq(1)
        expect(field.max).to eq(1000)
      end
    end
  end

  describe 'output_schema' do
    it 'has only page output schema' do
      expect(action.output_schema.map(&:reference)).to contain_exactly('page')
    end

    describe 'page schema' do
      let(:page_schema) { action.output_schema.first }

      it 'defines has_next_page and members fields' do
        page_schema.field(:has_next_page).tap do |field|
          expect(field.type).to eq(:boolean)
          expect(field.required).to be_truthy
        end

        members_field = page_schema.field(:members).tap do |field|
          expect(field.type).to eq(:nested)
          expect(field.array).to be_truthy
        end

        expect(members_field.field(:id).type).to eq(:string)
        expect(members_field.field(:id).required).to be_truthy
        expect(members_field.field(:name).type).to eq(:string)
        expect(members_field.field(:real_name).type).to eq(:string)
        expect(members_field.field(:is_admin).type).to eq(:boolean)
        expect(members_field.field(:is_bot).type).to eq(:boolean)
        expect(members_field.field(:is_restricted).type).to eq(:boolean)
        expect(members_field.field(:deleted).type).to eq(:boolean)
        expect(members_field.field(:profile).type).to eq(:hash)
      end
    end
  end

  describe 'iteration_state_schema' do
    it 'defines cursor field' do
      action.iteration_state_schema.field(:cursor).tap do |field|
        expect(field.type).to eq(:string)
        expect(field.required).to be_falsey
      end
    end
  end

  describe 'run' do
    let(:users_url) { "#{slack_api}/users.list" }
    let(:rate_limit_url) { users_url }
    let(:rate_limit_http_method) { :get }
    let(:rate_limit_input) { {} }

    it_behaves_like 'slack rate limiting'

    def trigger_action(input = {})
      run_action(input, schema_reference: 'page')
    end

    describe 'pagination' do
      it 'returns members and sets iteration_state_value on first page with next_cursor' do
        stub = stub_request(:get, users_url)
               .with(query: { limit: '200' })
               .to_return(status: 200, body: {
                 ok: true,
                 members: [
                   {
                     id: 'U001', name: 'alice', real_name: 'Alice', is_admin: true,
                     is_bot: false, is_restricted: false, deleted: false,
                     profile: { email: 'alice@example.com' },
                   },
                 ],
                 response_metadata: { next_cursor: 'abc123' },
               }.to_json)

        expect(action({})).to receive(:iteration_state_value=)
          .with({ cursor: 'abc123' })
          .and_call_original

        output = trigger_action
        expect(output[:has_next_page]).to eq(true)
        expect(output[:members].size).to eq(1)
        expect(output[:members].first[:id]).to eq('U001')
        expect(output[:members].first[:name]).to eq('alice')
        expect(stub).to have_been_requested.once
      end

      it 'clears iteration_state_value on last page with empty next_cursor' do
        stub = stub_request(:get, users_url)
               .with(query: { limit: '200' })
               .to_return(status: 200, body: {
                 ok: true,
                 members: [{ id: 'U002', name: 'bob' }],
                 response_metadata: { next_cursor: '' },
               }.to_json)

        expect(action({})).to receive(:iteration_state_value=)
          .with(nil)
          .and_call_original

        output = trigger_action
        expect(output[:has_next_page]).to eq(false)
        expect(output[:members].size).to eq(1)
        expect(stub).to have_been_requested.once
      end

      it 'sends cursor parameter when iteration_state_value is present' do
        stub = stub_request(:get, users_url)
               .with(query: { limit: '200', cursor: 'prev_cursor' })
               .to_return(status: 200, body: {
                 ok: true,
                 members: [{ id: 'U003', name: 'charlie' }],
                 response_metadata: { next_cursor: '' },
               }.to_json)

        action({}).send(:iteration_state_value=, { cursor: 'prev_cursor' })

        output = trigger_action
        expect(output[:has_next_page]).to eq(false)
        expect(stub).to have_been_requested.once
      end

      it 'uses custom limit parameter' do
        stub = stub_request(:get, users_url)
               .with(query: { limit: '50' })
               .to_return(status: 200, body: {
                 ok: true,
                 members: [],
                 response_metadata: { next_cursor: '' },
               }.to_json)

        trigger_action({ limit: 50 })
        expect(stub).to have_been_requested.once
      end

      it 'coalesces a present-but-nil limit to the default instead of sending empty' do
        # Schema defaults fill only absent keys, so a limit mapped to a nil-resolving
        # variable arrives present-but-nil; without the run-block coalescing this
        # would send limit= (empty).
        stub = stub_request(:get, users_url)
               .with(query: { limit: '200' })
               .to_return(status: 200, body: {
                 ok: true,
                 members: [],
                 response_metadata: { next_cursor: '' },
               }.to_json)

        trigger_action({ limit: nil })
        expect(stub).to have_been_requested.once
      end

      it 'treats an absent response_metadata as the terminal page' do
        stub_request(:get, users_url)
          .with(query: { limit: '200' })
          .to_return(status: 200, body: {
            ok: true,
            members: [{ id: 'U004', name: 'dana' }],
          }.to_json)

        expect(action({})).to receive(:iteration_state_value=)
          .with(nil)
          .and_call_original

        output = trigger_action
        expect(output[:has_next_page]).to eq(false)
        expect(output[:members].size).to eq(1)
      end

      it 'returns an empty members array when the members key is absent' do
        stub_request(:get, users_url)
          .with(query: { limit: '200' })
          .to_return(status: 200, body: {
            ok: true,
            response_metadata: { next_cursor: '' },
          }.to_json)

        output = trigger_action
        expect(output[:members]).to eq([])
        expect(output[:has_next_page]).to eq(false)
      end
    end

    describe 'error handling' do
      it 'fails on Slack API error' do
        stub_request(:get, users_url)
          .with(query: { limit: '200' })
          .to_return(status: 200, body: {
            ok: false,
            error: 'invalid_auth',
          }.to_json)

        expect { trigger_action }.to raise_error(
          IPaaS::Job::FailJob, 'Slack API error: invalid_auth'
        )
      end
    end
  end
end
