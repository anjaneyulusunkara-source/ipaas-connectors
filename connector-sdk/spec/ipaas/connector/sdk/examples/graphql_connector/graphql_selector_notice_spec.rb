require 'spec_helper'

# Mirrors xurrent_selector_notice_spec for the connector whose source label is lowercase and
# whose connection has no account field. The Xurrent copy used to be shared verbatim, so this
# connector rendered "the GraphQL API rejected..." and prescribed a field it does not have.
describe 'GraphQL Selector Notice', :action do
  include GraphqlIntrospectionHelper

  let(:connector_id) { 'd5bbb2a2-4a95-4b49-b490-56711e4455f8' }
  let(:action_template_id) { 'eb80d943-e0a3-44c7-97aa-640e243f9320' } # GraphQL Query
  let(:outbound_connection_config) { graphql_connector_outbound_connection_config }
  let(:graphql_endpoint) { graphql_connector_endpoint }
  let(:action_input) { {} }
  let(:schema_error_key) { IPaaS::Job::GraphQL::ArtifactCache::SCHEMA_ERROR_KEY }

  def stub_introspection_failure(status:, body: 'failure')
    stub_request(:post, graphql_endpoint)
      .with { |req| req.body.include?('__schema') }
      .to_return(status: status, body: body, headers: { 'content-type' => 'application/json' })
  end

  # The action resolves its input mapping while being built, so the introspection stub in
  # place at that point decides what the selector looks like.
  def object_field
    action(action_input).input_schema.field(:object)
  end

  describe 'with a schema available' do
    it 'offers the enumeration and no notice' do
      stub_graphql_connector_introspection
      built = action(action_input)
      field = built.input_schema.field(:object)

      expect(field.notice).to be_nil
      expect(field.enumeration).to include({ id: 'users', label: 'Users' })
      expect(built.outbound_connection.cache_read(schema_error_key)).to be_nil
    end
  end

  describe 'with no connection attached' do
    it 'asks for the connection to be configured' do
      field = action_template.input_schema.field(:object)

      expect(field.notice).to eq('Outbound Connection is not configured correctly.')
      expect(field.notice_type).to eq('error')
      expect(field.notice_action).to eq('edit_connection')
    end
  end

  describe 'with a failure the connection itself causes' do
    it 'names the credentials when they are what was rejected' do
      stub_introspection_failure(status: 401, body: 'Unauthorized')
      field = object_field

      expect(field.notice).to eq('Could not read the schema: the GraphQL API rejected the ' \
                                 'credentials in the Outbound Connection.')
      expect(field.notice_type).to eq('error')
      expect(field.notice_action).to eq('edit_connection')
      expect(field.enumeration).to be_blank
    end

    # graphql_endpoint is user-entered free text, so pointing at the host instead of /graphql
    # is the likeliest first-run mistake. It used to be diagnosed as bad credentials.
    it 'names the address when nothing answered there' do
      stub_introspection_failure(status: 404, body: 'Not Found')
      field = object_field

      expect(field.notice).to eq('Could not read the schema: nothing answered at the address ' \
                                 'in the Outbound Connection.')
      expect(field.notice).not_to include('credentials')
      expect(field.notice_action).to eq('edit_connection')
    end

    # This connection has graphql_endpoint, auth_type, tokens and custom_headers, and nothing
    # named account — the copy must not send the user looking for a field that is not there.
    it 'never prescribes a field this connection does not have' do
      stub_introspection_failure(status: 422, body: 'Unprocessable')
      field = object_field

      expect(field.notice).to eq('Could not read the schema: the GraphQL API rejected the ' \
                                 'request. Check the Outbound Connection.')
      expect(field.notice).not_to include('account')
    end

    [401, 404, 422, 503].each do |status|
      it "does not open the HTTP #{status} notice with the lowercase source label" do
        stub_introspection_failure(status: status)

        expect(object_field.notice).not_to start_with('the GraphQL API')
      end
    end
  end

  describe 'with a failure the connection cannot fix' do
    let(:transient_notice) do
      'Could not reach the GraphQL API to load the schema. This is usually temporary — ' \
        'reopen this step in a moment to try again.'
    end

    it 'reports a server error without blaming the connection' do
      stub_introspection_failure(status: 503, body: 'Service Unavailable')
      field = object_field

      expect(field.notice).to eq(transient_notice)
      expect(field.notice).not_to include('Service Unavailable')
      expect(field.notice_type).to eq('info')
      expect(field.notice_action).to be_nil
    end

    it 'reports an unreachable host' do
      stub_request(:post, graphql_endpoint).to_timeout
      field = object_field

      expect(field.notice).to eq(transient_notice)
      expect(field.notice_type).to eq('info')
      expect(field.notice_action).to be_nil
    end
  end

  describe 'with a fetch that has not succeeded yet' do
    it 'says so as information rather than as a connection error' do
      stub_request(:post, graphql_endpoint).to_timeout
      built = action(action_input)
      built.outbound_connection.cache_clear(schema_error_key)
      built.regenerate_schema(built.input_schema)

      field = built.input_schema.field(:object)

      expect(field.notice).to eq('The schema from the GraphQL API has not loaded yet. ' \
                                 'Reopen this step to load it.')
      expect(field.notice_type).to eq('info')
      expect(field.notice_action).to be_nil
    end
  end
end
