require 'spec_helper'

describe IPaaS::Job::GraphQL::ArtifactCache do
  # In-memory stand-in for the outbound connection: writes serialize to JSON and reads parse it
  # back, so stored symbol keys surface as strings exactly like the real cache.
  class FakeConnection
    attr_reader :ttls

    def initialize
      @entries = {}
      @ttls = {}
    end

    def cache_read(key)
      raw = @entries[key]
      raw.nil? ? nil : JSON.parse(raw)
    end

    def cache_write(key, value, ttl)
      @entries[key] = JSON.generate(value)
      @ttls[key] = ttl
      value
    end

    def cache_clear(key)
      @entries.delete(key)
      @ttls.delete(key)
    end

    def store
      @store ||= FakeDurableStore.new
    end
  end

  subject(:cache) { described_class }

  let(:connection) { FakeConnection.new }
  let(:keys_in) { %w[is_connection field_selection input_fields] }
  let(:keys_out) { %w[output_fields] }

  def valid_in_bundle(extra = {})
    { 'is_connection' => false, 'field_selection' => 'id name', 'input_fields' => [] }.merge(extra)
  end

  describe 'generation lifecycle' do
    it 'returns nil when no generation is established' do
      expect(cache.gql_bundle_generation(connection)).to be_nil
    end

    it 'mints a fresh token on every bump and reads it back' do
      first = cache.gql_bump_bundle_generation(connection)
      expect(cache.gql_bundle_generation(connection)).to eq(first)

      second = cache.gql_bump_bundle_generation(connection)
      expect(second).not_to eq(first)
      expect(cache.gql_bundle_generation(connection)).to eq(second)
    end

    it 'keeps the generation on the durable store, out of the expiring cache' do
      token = cache.gql_bump_bundle_generation(connection)

      expect(connection.ttls.keys).not_to include(described_class::GENERATION_KEY)
      expect(connection.store.read(described_class::GENERATION_KEY)).to eq(token)
    end

    it 'cannot revive orphaned entries after the generation is lost' do
      cache.gql_write_root_options(connection, :query, [{ id: 'people', label: 'People' }])
      expect(cache.gql_read_root_options(connection, :query)).not_to be_nil

      connection.store.delete(described_class::GENERATION_KEY)
      cache.gql_write_root_options(connection, :mutation, [{ id: 'requestCreate', label: 'Create' }])

      expect(cache.gql_read_root_options(connection, :query)).to be_nil
    end
  end

  # Connections written before the token moved to the durable store must keep their derived
  # entries rather than rebuild, so the deploy costs no extra schema fetch.
  describe 'legacy generation adoption' do
    let(:options) { [{ id: 'people', label: 'People' }] }

    def seed_legacy_generation(value)
      connection.cache_write(described_class::LEGACY_GENERATION_KEY, value, described_class::BUNDLE_TTL)
    end

    it 'adopts a live legacy generation so entries written under it stay readable' do
      seed_legacy_generation(3)
      connection.cache_write(cache.gql_root_options_cache_key(:query, 3), options, described_class::BUNDLE_TTL)

      expect(cache.gql_bundle_generation(connection)).to eq('3')
      expect(cache.gql_read_root_options(connection, :query)).to eq(options)
    end

    # Promoting the adopted value would be a read-modify-write: a read that observed an empty
    # durable store can complete after a concurrent bump and revive what that bump orphaned.
    it 'never writes the adopted value, so a concurrent bump survives' do
      seed_legacy_generation(3)
      connection.cache_write(cache.gql_root_options_cache_key(:query, 3), options, described_class::BUNDLE_TTL)

      bumped = cache.gql_invalidate(connection, 'gql_schema')
      # The adopt step of a read that observed an empty durable store before the bump, resuming
      # after it. Calling gql_bundle_generation here instead would short-circuit on the bump and
      # never reach adoption, so it would pass even while the promotion existed.
      cache.gql_adopt_legacy_generation(connection)

      expect(connection.store.read(described_class::GENERATION_KEY)).to eq(bumped)
      expect(cache.gql_read_root_options(connection, :query)).to be_nil
    end

    it 'keeps adopting for as long as the legacy entry is live' do
      seed_legacy_generation(3)

      expect(cache.gql_bundle_generation(connection)).to eq('3')
      expect(cache.gql_bundle_generation(connection)).to eq('3')
    end

    it 'prefers an established durable token over a legacy one' do
      token = cache.gql_bump_bundle_generation(connection)
      seed_legacy_generation(3)

      expect(cache.gql_bundle_generation(connection)).to eq(token)
    end

    it 'fails closed when no legacy generation is cached either' do
      expect(cache.gql_bundle_generation(connection)).to be_nil
      expect(cache.gql_read_root_options(connection, :query)).to be_nil
    end
  end

  describe 'schema error' do
    it 'round-trips the reason and cause under SCHEMA_ERROR_TTL, and clears them' do
      cache.gql_write_schema_error(connection, 'boom', cause: :credentials)
      expect(cache.gql_read_schema_error(connection))
        .to eq('reason' => 'boom', 'cause' => 'credentials')
      expect(connection.ttls[described_class::SCHEMA_ERROR_KEY]).to eq(described_class::SCHEMA_ERROR_TTL)

      cache.gql_clear_schema_error(connection)
      expect(cache.gql_read_schema_error(connection)).to be_nil
    end

    it 'truncates a reason too long for a field notice' do
      cache.gql_write_schema_error(connection, 'x' * 500, cause: :transient)

      expect(cache.gql_read_schema_error(connection)['reason'].length)
        .to eq(described_class::SCHEMA_ERROR_REASON_LIMIT)
    end

    it 'no-ops without a connection' do
      expect(cache.gql_write_schema_error(nil, 'boom', cause: :credentials))
        .to include('reason' => 'boom')
      expect(cache.gql_read_schema_error(nil)).to be_nil
    end
  end

  # The status picks the remedy and is never rendered, so the mapping is asserted per status
  # rather than only through the two codes the connector specs happen to stub.
  describe 'gql_schema_error_cause' do
    {
      401 => :credentials, 403 => :credentials,
      404 => :address, 405 => :address,
      408 => :transient, 429 => :transient,
      400 => :rejected, 422 => :rejected, 499 => :rejected,
      500 => :transient, 503 => :transient, 302 => :transient,
    }.each do |status, expected|
      it "classifies #{status} as #{expected}" do
        expect(cache.gql_schema_error_cause(status)).to eq(expected)
      end
    end

    # A rate limit is not the connection's fault, so it must never reach the branch that tells
    # the user to go and check it. Dormant today: backoff raises before this runs.
    it 'never blames the connection for a rate limit' do
      cache.gql_write_schema_error(connection, 'Too Many Requests', cause: cache.gql_schema_error_cause(429))
      notice = cache.gql_selector_notice(connection, 'Xurrent')

      expect(notice[:notice_type]).to eq('info')
      expect(notice[:notice_action]).to be_nil
    end
  end

  describe 'gql_seed_root_options' do
    let(:options) { [{ id: 'people', label: 'People' }] }

    it 'seeds when nothing is cached yet' do
      cache.gql_seed_root_options(connection, :query, options)

      expect(cache.gql_read_root_options(connection, :query)).to eq(options)
    end

    it 'leaves an already-cached enumeration alone' do
      cache.gql_write_root_options(connection, :query, options)
      cache.gql_seed_root_options(connection, :query, [{ id: 'requests', label: 'Requests' }])

      expect(cache.gql_read_root_options(connection, :query)).to eq(options)
    end

    it 'never caches a blank enumeration' do
      cache.gql_seed_root_options(connection, :query, [])

      expect(cache.gql_read_root_options(connection, :query)).to be_nil
    end
  end

  describe 'gql_selector_notice' do
    it 'blames the connection only when none is attached' do
      expect(cache.gql_selector_notice(nil, 'Xurrent'))
        .to eq(notice: 'Outbound Connection is not configured correctly.',
               notice_type: 'error', notice_action: 'edit_connection')
    end

    it 'names the credentials when they are what was rejected' do
      cache.gql_write_schema_error(connection, "HTTP 401 'Unauthorized'", cause: :credentials)
      notice = cache.gql_selector_notice(connection, 'Xurrent')

      expect(notice[:notice]).to eq('Could not read the schema: Xurrent rejected the credentials ' \
                                    'in the Outbound Connection.')
      expect(notice[:notice_type]).to eq('error')
      expect(notice[:notice_action]).to eq('edit_connection')
    end

    # A 404 means the endpoint is wrong, not the credentials, and nothing rejected anything —
    # so the copy names the address and never names the source as a rejecter.
    it 'names the address when nothing answered there' do
      cache.gql_write_schema_error(connection, "HTTP 404 'Not Found'", cause: :address)
      notice = cache.gql_selector_notice(connection, 'the GraphQL API')

      expect(notice[:notice]).to eq('Could not read the schema: nothing answered at the address ' \
                                    'in the Outbound Connection.')
      expect(notice[:notice]).not_to include('credentials')
      expect(notice[:notice]).not_to include('the GraphQL API')
      expect(notice[:notice_action]).to eq('edit_connection')
    end

    # The connection is at fault but the status does not say which part of it, so the copy
    # must not prescribe a field — 'account' exists on Xurrent and on no other GraphQL connection.
    it 'stays unspecific for a rejection it cannot attribute to a field' do
      cache.gql_write_schema_error(connection, "HTTP 422 'Unprocessable'", cause: :rejected)
      notice = cache.gql_selector_notice(connection, 'Xurrent')

      expect(notice[:notice]).to eq('Could not read the schema: Xurrent rejected the request. ' \
                                    'Check the Outbound Connection.')
      expect(notice[:notice]).not_to include('account')
      expect(notice[:notice_action]).to eq('edit_connection')
    end

    it 'does not blame the connection for a transient failure' do
      cache.gql_write_schema_error(connection, 'Too Many Requests', cause: :transient)
      notice = cache.gql_selector_notice(connection, 'Xurrent')

      expect(notice[:notice]).to eq('Could not reach Xurrent to load the schema. This is usually ' \
                                    'temporary — reopen this step in a moment to try again.')
      expect(notice[:notice_type]).to eq('info')
      expect(notice[:notice_action]).to be_nil
    end

    # A record written before the cause enum shipped has no 'cause', and an unblamed info
    # notice is the safe reading of one.
    it 'does not blame the connection for a cause it does not recognise' do
      connection.cache_write(described_class::SCHEMA_ERROR_KEY, { 'reason' => 'boom' }, 60)
      notice = cache.gql_selector_notice(connection, 'Xurrent')

      expect(notice[:notice_type]).to eq('info')
      expect(notice[:notice_action]).to be_nil
    end

    it 'never renders the recorded upstream message' do
      cache.gql_write_schema_error(connection, "HTTP 400 'secret-ish upstream body'", cause: :rejected)

      expect(cache.gql_selector_notice(connection, 'Xurrent')[:notice]).not_to include('upstream body')
      expect(cache.gql_read_schema_error(connection)['reason']).to include('upstream body')
    end

    it 'reports a fetch that has not succeeded yet as information' do
      notice = cache.gql_selector_notice(connection, 'Xurrent')

      expect(notice[:notice]).to eq('The schema from Xurrent has not loaded yet. ' \
                                    'Reopen this step to load it.')
      expect(notice[:notice_type]).to eq('info')
      expect(notice[:notice_action]).to be_nil
    end

    # Defect this replaced: the copy led with the source, so the connector whose label is
    # lowercase rendered a sentence starting mid-word.
    [:credentials, :address, :rejected, :transient].each do |cause|
      it "does not open the #{cause} notice with the source label" do
        cache.gql_write_schema_error(connection, 'boom', cause: cause)

        expect(cache.gql_selector_notice(connection, 'the GraphQL API')[:notice])
          .not_to start_with('the GraphQL API')
      end
    end
  end

  describe 'gql_invalidate' do
    it 'clears the given keys and bumps the generation, orphaning prior derived entries' do
      connection.cache_write('gql_schema', { '__schema' => {} }, 10)
      connection.cache_write('introspection_failure_abc', 'boom', 10)
      cache.gql_write_root_options(connection, :query, [{ id: 'people', label: 'People' }]) # establishes one
      gen_before = cache.gql_bundle_generation(connection)

      cache.gql_invalidate(connection, 'gql_schema', 'introspection_failure_abc')

      expect(connection.cache_read('gql_schema')).to be_nil
      expect(connection.cache_read('introspection_failure_abc')).to be_nil
      expect(cache.gql_bundle_generation(connection)).not_to eq(gen_before)
      expect(cache.gql_read_root_options(connection, :query)).to be_nil # orphaned by the bump
    end

    # Refresh schema is the user saying "try again", so the recorded reason must not outlive it
    # and keep driving the notice for the rest of its own TTL.
    it 'clears the recorded schema error' do
      cache.gql_write_schema_error(connection, 'boom', cause: :credentials)

      cache.gql_invalidate(connection, 'gql_schema')

      expect(cache.gql_read_schema_error(connection)).to be_nil
    end
  end

  describe 'fail-closed reads when no generation is established' do
    it 'gql_load_bundle returns nil' do
      expect(cache.gql_load_bundle(connection, :query, 'in',
                                   selection_name: 'people', include_fields: {},
                                   required_keys: keys_in)).to be_nil
    end

    it 'gql_warm_for_regeneration? returns false' do
      expect(cache.gql_warm_for_regeneration?(connection, :query,
                                              selection_present: true, selection_name: 'people',
                                              include_fields: {}, required_keys_in: keys_in,
                                              required_keys_out: keys_out)).to be(false)
    end
  end

  describe 'bundle write/read round-trip' do
    before { cache.gql_bump_bundle_generation(connection) }

    it 'reads back a written bundle part for the same selection and include_fields' do
      cache.gql_write_bundle_part(connection, :query, 'in',
                                  selection_name: 'people', include_fields: { team: true },
                                  bundle: valid_in_bundle)
      loaded = cache.gql_load_bundle(connection, :query, 'in',
                                     selection_name: 'people', include_fields: { team: true },
                                     required_keys: keys_in)
      expect(loaded).to include('is_connection' => false, 'field_selection' => 'id name')
    end

    it 'writes the bundle under BUNDLE_TTL' do
      cache.gql_write_bundle_part(connection, :query, 'in',
                                  selection_name: 'people', include_fields: {},
                                  bundle: valid_in_bundle)
      written_key = connection.ttls.keys.find { |k| k.start_with?('gql_bundle_in_') }
      expect(connection.ttls[written_key]).to eq(described_class::BUNDLE_TTL)
    end

    it 'does not read a bundle orphaned by a later generation bump' do
      cache.gql_write_bundle_part(connection, :query, 'in',
                                  selection_name: 'people', include_fields: {},
                                  bundle: valid_in_bundle)
      cache.gql_bump_bundle_generation(connection)
      expect(cache.gql_load_bundle(connection, :query, 'in',
                                   selection_name: 'people', include_fields: {},
                                   required_keys: keys_in)).to be_nil
    end

    it 'does not read a bundle for a different include_fields selection' do
      cache.gql_write_bundle_part(connection, :query, 'in',
                                  selection_name: 'people', include_fields: { team: true },
                                  bundle: valid_in_bundle)
      expect(cache.gql_load_bundle(connection, :query, 'in',
                                   selection_name: 'people', include_fields: { team: false },
                                   required_keys: keys_in)).to be_nil
    end
  end

  describe 'digest keying' do
    it 'collapses logically-equal include_fields to one key' do
      k1 = cache.gql_bundle_cache_key(:query, 'in', 'people', { a: true, b: false }, 1)
      k2 = cache.gql_bundle_cache_key(:query, 'in', 'people', { 'b' => false, 'a' => true }, 1)
      expect(k1).to eq(k2)
    end

    it 'keeps {a: false} distinct from {} (explicit false leaf preserved)' do
      with_false = cache.gql_bundle_cache_key(:query, 'in', 'people', { a: false }, 1)
      empty = cache.gql_bundle_cache_key(:query, 'in', 'people', {}, 1)
      expect(with_false).not_to eq(empty)
    end

    it 'embeds the part and generation in the key' do
      expect(cache.gql_bundle_cache_key(:query, 'in', 'people', {}, 7)).to start_with('gql_bundle_in_7_')
    end
  end

  describe 'gql_stable_json' do
    it 'sorts hash keys regardless of insertion order or key class' do
      expect(cache.gql_stable_json({ b: 1, a: 2 })).to eq(cache.gql_stable_json({ 'a' => 2, 'b' => 1 }))
    end

    it 'keeps {a: false} distinct from {}' do
      expect(cache.gql_stable_json({ a: false })).not_to eq(cache.gql_stable_json({}))
    end
  end

  describe 'defensive shape validation' do
    before { cache.gql_bump_bundle_generation(connection) }

    it 'rejects a non-hash bundle entry' do
      key = cache.gql_bundle_cache_key(:query, 'in', 'people', {}, cache.gql_bundle_generation(connection))
      connection.cache_write(key, [1, 2, 3], 10)
      expect(cache.gql_load_bundle(connection, :query, 'in',
                                   selection_name: 'people', include_fields: {},
                                   required_keys: keys_in)).to be_nil
    end

    it 'rejects a bundle missing a required key' do
      cache.gql_write_bundle_part(connection, :query, 'in',
                                  selection_name: 'people', include_fields: {},
                                  bundle: { 'is_connection' => false, 'input_fields' => [] })
      expect(cache.gql_load_bundle(connection, :query, 'in',
                                   selection_name: 'people', include_fields: {},
                                   required_keys: keys_in)).to be_nil
    end

    it 'rejects a bundle whose descriptor list is malformed' do
      cache.gql_write_bundle_part(connection, :query, 'in',
                                  selection_name: 'people', include_fields: {},
                                  bundle: valid_in_bundle('input_fields' => [{}]))
      expect(cache.gql_load_bundle(connection, :query, 'in',
                                   selection_name: 'people', include_fields: {},
                                   required_keys: keys_in)).to be_nil
    end

    it 'accepts a bundle whose descriptor list is well-formed' do
      good = valid_in_bundle('input_fields' => [{ 'id' => 'x', 'label' => 'X', 'type' => 'string' }])
      cache.gql_write_bundle_part(connection, :query, 'in', selection_name: 'people', include_fields: {}, bundle: good)
      expect(cache.gql_load_bundle(connection, :query, 'in',
                                   selection_name: 'people', include_fields: {},
                                   required_keys: keys_in)).not_to be_nil
    end
  end

  describe 'gql_valid_descriptor_list?' do
    it 'accepts a valid nested descriptor list' do
      list = [{ 'id' => 'a', 'label' => 'A', 'type' => 'nested',
                'fields' => [{ 'id' => 'b', 'label' => 'B', 'type' => 'string' }], }]
      expect(cache.gql_valid_descriptor_list?(list)).to be(true)
    end

    it 'accepts a well-formed enumeration' do
      list = [{ 'id' => 'a', 'label' => 'A', 'type' => 'string', 'enumeration' => [{ 'id' => 'x', 'label' => 'X' }] }]
      expect(cache.gql_valid_descriptor_list?(list)).to be(true)
    end

    it 'rejects a non-array' do
      expect(cache.gql_valid_descriptor_list?({ 'id' => 'a' })).to be(false)
    end

    it 'rejects an entry missing id, label, or type' do
      expect(cache.gql_valid_descriptor_list?([{ 'id' => 'a', 'label' => 'A' }])).to be(false)
    end

    it 'rejects a non-string id' do
      expect(cache.gql_valid_descriptor_list?([{ 'id' => 1, 'label' => 'A', 'type' => 'string' }])).to be(false)
    end

    it 'rejects a malformed enumeration entry' do
      list = [{ 'id' => 'a', 'label' => 'A', 'type' => 'string', 'enumeration' => [{ 'id' => 'x' }] }]
      expect(cache.gql_valid_descriptor_list?(list)).to be(false)
    end

    it 'rejects a malformed nested fields list' do
      list = [{ 'id' => 'a', 'label' => 'A', 'type' => 'nested', 'fields' => [{}] }]
      expect(cache.gql_valid_descriptor_list?(list)).to be(false)
    end
  end

  describe 'root-field options' do
    it 'fails closed when no generation is established' do
      expect(cache.gql_read_root_options(connection, :query)).to be_nil
    end

    it 'round-trips written options normalized to id/label symbol keys' do
      cache.gql_write_root_options(connection, :query, [{ id: 'people', label: 'People' }])
      expect(cache.gql_read_root_options(connection, :query)).to eq([{ id: 'people', label: 'People' }])
    end

    it 'does not read options orphaned by a later generation bump' do
      cache.gql_write_root_options(connection, :query, [{ id: 'people', label: 'People' }])
      cache.gql_bump_bundle_generation(connection)
      expect(cache.gql_read_root_options(connection, :query)).to be_nil
    end
  end

  describe 'gql_warm_for_regeneration?' do
    before { cache.gql_bump_bundle_generation(connection) }

    def warm_root_options
      cache.gql_write_root_options(connection, :query, [{ id: 'people', label: 'People' }])
    end

    it 'is false when root options are absent (even with both bundle parts warm)' do
      cache.gql_write_bundle_part(connection, :query, 'in',
                                  selection_name: 'people', include_fields: {},
                                  bundle: valid_in_bundle)
      cache.gql_write_bundle_part(connection, :query, 'out',
                                  selection_name: 'people', include_fields: {},
                                  bundle: { 'output_fields' => [] })
      expect(cache.gql_warm_for_regeneration?(connection, :query,
                                              selection_present: true, selection_name: 'people',
                                              include_fields: {}, required_keys_in: keys_in,
                                              required_keys_out: keys_out)).to be(false)
    end

    it 'is true with root options when no selection has been made yet' do
      warm_root_options
      expect(cache.gql_warm_for_regeneration?(connection, :query,
                                              selection_present: false, selection_name: nil,
                                              include_fields: {}, required_keys_in: keys_in,
                                              required_keys_out: keys_out)).to be(true)
    end

    it 'is false when a selection is made but a bundle part is missing' do
      warm_root_options
      cache.gql_write_bundle_part(connection, :query, 'in',
                                  selection_name: 'people', include_fields: {},
                                  bundle: valid_in_bundle)
      expect(cache.gql_warm_for_regeneration?(connection, :query,
                                              selection_present: true, selection_name: 'people',
                                              include_fields: {}, required_keys_in: keys_in,
                                              required_keys_out: keys_out)).to be(false)
    end

    it 'is true when root options and both bundle parts are warm' do
      warm_root_options
      cache.gql_write_bundle_part(connection, :query, 'in',
                                  selection_name: 'people', include_fields: {},
                                  bundle: valid_in_bundle)
      cache.gql_write_bundle_part(connection, :query, 'out',
                                  selection_name: 'people', include_fields: {},
                                  bundle: { 'output_fields' => [] })
      expect(cache.gql_warm_for_regeneration?(connection, :query,
                                              selection_present: true, selection_name: 'people',
                                              include_fields: {}, required_keys_in: keys_in,
                                              required_keys_out: keys_out)).to be(true)
    end
  end

  describe 'nil connection (unconfigured action)' do
    it 'reads degrade to nil' do
      expect(cache.gql_cache_read(nil, 'k')).to be_nil
      expect(cache.gql_bundle_generation(nil)).to be_nil
      expect(cache.gql_load_bundle(nil, :query, 'in',
                                   selection_name: 'people', include_fields: {},
                                   required_keys: keys_in)).to be_nil
      expect(cache.gql_read_root_options(nil, :query)).to be_nil
    end

    it 'writes are a no-op returning the value' do
      expect(cache.gql_cache_write(nil, 'k', 'v', 10)).to eq('v')
    end

    it 'a bump mints a token without persisting it' do
      expect(cache.gql_bump_bundle_generation(nil)).to match(/\A[0-9a-f]{16}\z/)
      expect(cache.gql_bundle_generation(nil)).to be_nil
    end

    it 'clears are a no-op returning nil' do
      expect(cache.gql_cache_clear(nil, 'k')).to be_nil
    end
  end
end
