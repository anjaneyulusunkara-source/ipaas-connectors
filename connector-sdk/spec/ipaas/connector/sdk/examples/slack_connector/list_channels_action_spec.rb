require 'spec_helper'

describe 'Slack List Channels Action', :action, :slack do
  let(:action_template_id) { '019d6e9d-90c5-7201-bcf2-1cc1b189a11c' }

  describe 'input_schema' do
    it 'defines the types field' do
      action.input_schema.field(:types).tap do |field|
        expect(field.label).to eq('Types')
        expect(field.type).to eq(:string)
        expect(field.required).to be_falsey
      end
    end

    it 'defines the exclude_archived field' do
      action.input_schema.field(:exclude_archived).tap do |field|
        expect(field.label).to eq('Exclude archived')
        expect(field.type).to eq(:boolean)
        expect(field.required).to be_falsey
      end
    end

    it 'defines the limit field' do
      action.input_schema.field(:limit).tap do |field|
        expect(field.label).to eq('Limit')
        expect(field.type).to eq(:integer)
        expect(field.required).to be_falsey
      end
    end
  end

  describe 'output_schema' do
    it 'has only the page schema' do
      expect(action.output_schema.map(&:reference)).to contain_exactly('page')
    end

    describe 'page schema' do
      let(:page_schema) { action.output_schema.first }

      it 'defines the has_next_page field' do
        page_schema.field(:has_next_page).tap do |field|
          expect(field.label).to eq('Has next page')
          expect(field.type).to eq(:boolean)
          expect(field.required).to be_truthy
        end
      end

      it 'defines the channels field with nested fields' do
        channels_field = page_schema.field(:channels).tap do |field|
          expect(field.label).to eq('Channels')
          expect(field.type).to eq(:nested)
          expect(field.array).to eq(true)
        end

        channels_field.field(:id).tap do |field|
          expect(field.label).to eq('ID')
          expect(field.type).to eq(:string)
        end

        channels_field.field(:name).tap do |field|
          expect(field.label).to eq('Name')
          expect(field.type).to eq(:string)
        end

        channels_field.field(:is_channel).tap do |field|
          expect(field.type).to eq(:boolean)
        end

        channels_field.field(:is_private).tap do |field|
          expect(field.type).to eq(:boolean)
        end

        channels_field.field(:is_archived).tap do |field|
          expect(field.type).to eq(:boolean)
        end

        channels_field.field(:num_members).tap do |field|
          expect(field.type).to eq(:integer)
        end

        channels_field.field(:creator).tap do |field|
          expect(field.type).to eq(:string)
        end

        channels_field.field(:created).tap do |field|
          expect(field.type).to eq(:integer)
        end
      end
    end
  end

  describe 'iteration_state_schema' do
    it 'defines the cursor field' do
      action.iteration_state_schema.field(:cursor).tap do |field|
        expect(field.label).to eq('Cursor')
        expect(field.type).to eq(:string)
        expect(field.required).to be_falsey
      end
    end
  end

  describe 'run' do
    let(:rate_limit_url) { "#{slack_api}/conversations.list" }
    let(:rate_limit_http_method) { :get }
    let(:rate_limit_input) { {} }

    it_behaves_like 'slack rate limiting'

    def trigger_action(input = {})
      run_action(input, schema_reference: 'page')
    end

    describe 'pagination' do
      context 'when more pages available' do
        before do
          stub_request(:get, "#{slack_api}/conversations.list")
            .with(query: hash_including({}))
            .to_return(status: 200, body: {
              ok: true,
              channels: [{ id: 'C1', name: 'general' }],
              response_metadata: { next_cursor: 'cursor_abc' },
            }.to_json)
        end

        it 'sets iteration state for next page and returns channels' do
          expect(action({}))
            .to receive(:iteration_state_value=)
            .with({ cursor: 'cursor_abc' })
            .and_call_original

          output = trigger_action
          expect(output[:has_next_page]).to be(true)
          expect(output[:channels].length).to eq(1)
          expect(output[:channels].first['id']).to eq('C1')
          expect(output[:channels].first['name']).to eq('general')
        end
      end

      context 'when on last page' do
        before do
          stub_request(:get, "#{slack_api}/conversations.list")
            .with(query: hash_including({}))
            .to_return(status: 200, body: {
              ok: true,
              channels: [{ id: 'C2', name: 'random' }],
              response_metadata: { next_cursor: '' },
            }.to_json)
        end

        it 'clears iteration state' do
          expect(action({}))
            .to receive(:iteration_state_value=)
            .with(nil)
            .and_call_original

          output = trigger_action
          expect(output[:has_next_page]).to be(false)
          expect(output[:channels].length).to eq(1)
        end
      end

      context 'when response_metadata is absent (nil cursor)' do
        before do
          stub_request(:get, "#{slack_api}/conversations.list")
            .with(query: hash_including({}))
            .to_return(status: 200, body: {
              ok: true,
              channels: [{ id: 'C4', name: 'ops' }],
            }.to_json)
        end

        it 'treats it as the terminal page and clears iteration state' do
          expect(action({}))
            .to receive(:iteration_state_value=)
            .with(nil)
            .and_call_original

          output = trigger_action
          expect(output[:has_next_page]).to be(false)
          expect(output[:channels].length).to eq(1)
        end
      end

      context 'when the channels key is absent' do
        before do
          stub_request(:get, "#{slack_api}/conversations.list")
            .with(query: hash_including({}))
            .to_return(status: 200, body: {
              ok: true,
              response_metadata: { next_cursor: '' },
            }.to_json)
        end

        it 'returns an empty channels array' do
          output = trigger_action
          expect(output[:channels]).to eq([])
          expect(output[:has_next_page]).to be(false)
        end
      end

      it 'uses iteration_state_value for subsequent pages' do
        stub = stub_request(:get, "#{slack_api}/conversations.list")
               .with(query: hash_including('cursor' => 'cursor_xyz'))
               .to_return(status: 200, body: {
                 ok: true,
                 channels: [{ id: 'C3', name: 'dev' }],
                 response_metadata: { next_cursor: '' },
               }.to_json)

        action({}).send(:iteration_state_value=, { cursor: 'cursor_xyz' })

        output = trigger_action
        expect(output[:has_next_page]).to be(false)
        expect(output[:channels].length).to eq(1)
        expect(stub).to have_been_requested.once
      end

      it 'advances across iterations: the cursor set on page 1 is read on page 2' do
        # Most-recently-declared matching stub wins in WebMock, so the cursor-bearing
        # page-2 stub takes precedence over the catch-all page-1 stub for the 2nd call.
        stub_request(:get, "#{slack_api}/conversations.list")
          .with(query: hash_including({}))
          .to_return(status: 200, body: {
            ok: true,
            channels: [{ id: 'C1', name: 'general' }],
            response_metadata: { next_cursor: 'cursor_abc' },
          }.to_json)
        page2 = stub_request(:get, "#{slack_api}/conversations.list")
                .with(query: hash_including('cursor' => 'cursor_abc'))
                .to_return(status: 200, body: {
                  ok: true,
                  channels: [{ id: 'C2', name: 'random' }],
                  response_metadata: { next_cursor: '' },
                }.to_json)

        first = trigger_action
        expect(first[:has_next_page]).to be(true)
        expect(first[:channels].first['id']).to eq('C1')

        # Second iteration reuses the same action/runbook, so the cursor stored from
        # page 1 must be read back through iteration_state_value(:cursor) and sent.
        second = trigger_action
        expect(second[:has_next_page]).to be(false)
        expect(second[:channels].first['id']).to eq('C2')

        expect(page2).to have_been_requested.once
        expect(
          a_request(:get, "#{slack_api}/conversations.list").with(query: hash_including({})),
        ).to have_been_made.twice
      end
    end

    describe 'default parameters' do
      it 'sends default types, exclude_archived, and limit' do
        stub = stub_request(:get, "#{slack_api}/conversations.list")
               .with(query: hash_including(
                 'types' => 'public_channel',
                 'exclude_archived' => 'true',
                 'limit' => '200',
               ))
               .to_return(status: 200, body: {
                 ok: true,
                 channels: [],
                 response_metadata: { next_cursor: '' },
               }.to_json)

        trigger_action
        expect(stub).to have_been_requested.once
      end

      it 'coalesces present-but-nil inputs to defaults instead of sending empty params' do
        # Schema defaults are backfilled only for ABSENT keys, so an optional field
        # mapped to a nil-resolving variable arrives present-but-nil. Without the
        # run-block coalescing this would send empty params (e.g. exclude_archived=,
        # silently surfacing archived channels).
        stub = stub_request(:get, "#{slack_api}/conversations.list")
               .with(query: hash_including(
                 'types' => 'public_channel',
                 'exclude_archived' => 'true',
                 'limit' => '200',
               ))
               .to_return(status: 200, body: {
                 ok: true,
                 channels: [],
                 response_metadata: { next_cursor: '' },
               }.to_json)

        trigger_action(types: nil, exclude_archived: nil, limit: nil)
        expect(stub).to have_been_requested.once
      end
    end

    describe 'error handling' do
      it 'fails on Slack API error' do
        stub_request(:get, "#{slack_api}/conversations.list")
          .with(query: hash_including({}))
          .to_return(status: 200, body: {
            ok: false,
            error: 'invalid_auth',
          }.to_json)

        expect { trigger_action }
          .to raise_error(IPaaS::Job::FailJob, /invalid_auth/)
      end

      it 'fails on HTTP error' do
        stub_request(:get, "#{slack_api}/conversations.list")
          .with(query: hash_including({}))
          .to_return(status: 500, body: 'Internal Server Error')

        expect { trigger_action }
          .to raise_error(IPaaS::Job::FailJob, /500/)
      end
    end
  end
end
