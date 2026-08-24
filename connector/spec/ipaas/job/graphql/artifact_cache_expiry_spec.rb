require 'spec_helper'

# Clock-driven counterpart to artifact_cache_spec.rb, whose FakeConnection never expires anything.
# 'generation lifetime' is the regression for request #80566194: the generation used to be a
# cache entry, so it expired before the entries it gates and failed every derived read closed
# while they were still valid, emptying the designer's object selector on a working connection.
# 'object selector population' covers the surrounding fallback order, which predates the bug.
describe IPaaS::Job::GraphQL::ArtifactCache do
  class ExpiringConnection
    attr_accessor :now

    def initialize
      @entries = {}
      @now = 0
    end

    # Untimed, like the real durable store: the clock must not reach the generation.
    def store
      @store ||= FakeDurableStore.new
    end

    def cache_read(key)
      entry = @entries[key]
      return nil if entry.nil?
      return nil if @now >= entry[:expires_at]

      JSON.parse(entry[:raw])
    end

    def cache_write(key, value, ttl)
      @entries[key] = { raw: JSON.generate(value), expires_at: @now + ttl }
      value
    end

    def cache_clear(key)
      @entries.delete(key)
    end

    def live_keys
      @entries.keys.select { |key| @now < @entries[key][:expires_at] }
    end
  end

  subject(:cache) { described_class }

  let(:connection) { ExpiringConnection.new }
  let(:keys_in) { %w[is_connection field_selection input_fields] }
  let(:root_options) { [{ 'id' => 'people', 'label' => 'People' }] }
  let(:day) { 24 * 3600 }
  let(:schema_ttl) { 3600 }

  def bundle_part
    { 'is_connection' => false, 'field_selection' => 'id', 'input_fields' => [] }
  end

  def warm(at: 0)
    connection.now = at
    cache.gql_write_root_options(connection, :query, root_options)
    cache.gql_write_bundle_part(connection, :query, 'in',
                                selection_name: 'people', include_fields: {}, bundle: bundle_part)
    connection.cache_write('gql_schema', { 'types' => [] }, schema_ttl)
  end

  def load_in_bundle
    cache.gql_load_bundle(connection, :query, 'in',
                          selection_name: 'people', include_fields: {}, required_keys: keys_in)
  end

  # Mirrors build_query_input_fields: the selector is populated from the bundle's root
  # options when warm, else the schema, else the root-options fallback.
  def selector_options
    cached_root = cache.gql_read_root_options(connection, :query)
    return cached_root if load_in_bundle && cached_root
    return [{ 'id' => 'people', 'label' => 'People' }] if connection.cache_read('gql_schema').present?

    cache.gql_read_root_options(connection, :query) || []
  end

  describe 'generation lifetime' do
    it 'keeps serving root options and bundle parts that are still live long after BUNDLE_TTL' do
      warm
      warm(at: day)
      connection.now = described_class::BUNDLE_TTL + 1
      generation = cache.gql_bundle_generation(connection)

      expect(connection.live_keys)
        .to include(cache.gql_root_options_cache_key(:query, generation),
                    cache.gql_bundle_cache_key(:query, 'in', 'people', {}, generation))
      expect(cache.gql_read_root_options(connection, :query)).to eq([{ id: 'people', label: 'People' }])
      expect(load_in_bundle).to include('field_selection' => 'id')
    end

    it 'never revives an orphaned entry when the generation is bumped' do
      cache.gql_write_root_options(connection, :query, root_options)
      expect(cache.gql_read_root_options(connection, :query)).to eq([{ id: 'people', label: 'People' }])

      cache.gql_bump_bundle_generation(connection)

      expect(cache.gql_read_root_options(connection, :query)).to be_nil
    end

    it 'outlives the entries it gates, however far the clock runs' do
      warm
      established = cache.gql_bundle_generation(connection)
      connection.now = 10 * 365 * day

      expect(cache.gql_bundle_generation(connection)).to eq(established)
    end
  end

  describe 'object selector population' do
    it 'falls back to the cached root options once the schema lapses' do
      warm
      connection.now = schema_ttl + 1

      expect(selector_options).to eq([{ id: 'people', label: 'People' }])
    end

    it 'keeps the fallback long after BUNDLE_TTL while entries are refreshed' do
      warm
      warm(at: day)
      connection.now = described_class::BUNDLE_TTL + 1

      expect(selector_options).to eq([{ id: 'people', label: 'People' }])
    end

    it 'serves an empty selector while a bump is pending and no schema is cached' do
      warm
      cache.gql_invalidate(connection, 'gql_schema')

      expect(selector_options).to eq([])
    end
  end
end
