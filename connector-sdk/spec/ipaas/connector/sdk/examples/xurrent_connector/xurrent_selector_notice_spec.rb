require 'spec_helper'

# Regression for request #80566194: an empty object selector used to report
# "Outbound Connection is not configured correctly." whatever had actually gone wrong,
# on connections that tested green. Only an unattached connection earns that message
# now; a schema fetch that failed reports its own reason.
describe 'Xurrent Selector Notice', :action do
  include XurrentIntrospectionHelper

  let(:action_template_id) { '019ce240-76c9-75d1-beac-8c07b2325e76' }
  let(:outbound_connection_config) { xurrent_outbound_connection_config }
  let(:graphql_endpoint) { xurrent_graphql_endpoint }
  let(:action_input) { {} }
  let(:schema_error_key) { IPaaS::Job::GraphQL::ArtifactCache::SCHEMA_ERROR_KEY }

  def stub_introspection_failure(status:, body: 'failure')
    stub_request(:post, graphql_endpoint)
      .with { |req| req.body.include?('__schema') }
      .to_return(status: status, body: body, headers: { 'content-type' => 'application/json' })
  end

  def stub_oauth
    stub_request(:post, /oauth\./)
      .to_return(status: 200, body: { access_token: 'tok', token_type: 'bearer' }.to_json,
                 headers: { 'content-type' => 'application/json' })
  end

  # The action resolves its input mapping while being built, so the introspection stub in
  # place at that point decides what the selector looks like.
  def cold_action
    stub_oauth
    action(action_input)
  end

  def object_field(built = cold_action)
    built.input_schema.field(:object)
  end

  describe 'with a schema available' do
    it 'offers the enumeration and no notice' do
      stub_introspection
      built = cold_action
      field = built.input_schema.field(:object)

      expect(field.notice).to be_nil
      expect(field.enumeration).to contain_exactly({ id: 'people', label: 'People' },
                                                   { id: 'me', label: 'Me' })
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

  let(:transient_notice) do
    'Could not reach Xurrent to load the schema. This is usually temporary — ' \
      'reopen this step in a moment to try again.'
  end

  describe 'with a failure the connection itself causes' do
    it 'points at the connection without quoting the upstream response' do
      stub_introspection_failure(status: 400, body: 'Invalid x-xurrent-account header')
      field = object_field

      expect(field.notice).to eq('Could not read the schema: Xurrent rejected the request. ' \
                                 'Check the Outbound Connection.')
      expect(field.notice).not_to include('x-xurrent-account')
      expect(field.notice_type).to eq('error')
      expect(field.notice_action).to eq('edit_connection')
      expect(field.enumeration).to be_blank
    end

    it 'names the credentials when they are what was rejected' do
      stub_introspection_failure(status: 401, body: 'Unauthorized')
      field = object_field

      expect(field.notice).to eq('Could not read the schema: Xurrent rejected the credentials ' \
                                 'in the Outbound Connection.')
      expect(field.notice_action).to eq('edit_connection')
    end

    # The endpoint is user-entered, so a wrong one is the likeliest first-run mistake. It used
    # to be diagnosed as a credentials problem, which is the one thing it is not.
    it 'names the address when nothing answered there' do
      stub_introspection_failure(status: 404, body: 'Not Found')
      field = object_field

      expect(field.notice).to eq('Could not read the schema: nothing answered at the address ' \
                                 'in the Outbound Connection.')
      expect(field.notice).not_to include('credentials')
      expect(field.notice_action).to eq('edit_connection')
    end
  end

  describe 'with a failure the connection cannot fix' do
    it 'reports a rate limit without blaming the connection' do
      stub_introspection_failure(status: 429, body: 'Too Many Requests')
      field = object_field

      expect(field.notice).to eq(transient_notice)
      expect(field.notice).not_to include('not configured correctly')
      expect(field.notice_type).to eq('info')
      expect(field.notice_action).to be_nil
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
      built = cold_action
      built.outbound_connection.cache_clear(schema_error_key)
      built.regenerate_schema(built.input_schema)

      field = built.input_schema.field(:object)

      expect(field.notice).to eq('The schema from Xurrent has not loaded yet. ' \
                                 'Reopen this step to load it.')
      expect(field.notice_type).to eq('info')
      expect(field.notice_action).to be_nil
    end
  end
end
