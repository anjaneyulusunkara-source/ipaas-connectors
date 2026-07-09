require 'spec_helper'

describe IPaaS::Connector::Types::HashedCredentialType do
  let(:plaintext) { 'correct horse battery staple' }
  let(:credential) { IPaaS::Encryption::HashedCredential.derive(plaintext) }
  let(:record) { credential.to_h }

  it 'defines the ruby class' do
    expect(subject.ruby_class).to eq(IPaaS::Encryption::HashedCredential)
  end

  it 'is nested and variable-resolvable' do
    expect(subject.nested?).to be(true)
    expect(subject.variable_resolvable?).to be(true)
  end

  describe 'registration' do
    it 'is registered as :hashed_credential after requiring the connector' do
      require 'ipaas/connector'
      expect(IPaaS::Connector::Types.for(:hashed_credential)).to eq(described_class)
    end
  end

  describe 'resolve' do
    it 'leaves nils untouched' do
      expect(subject.resolve(nil)).to be_nil
    end

    it 'returns an existing HashedCredential unchanged (identity)' do
      expect(subject.resolve(credential)).to be(credential)
    end

    it 'wraps a well-formed derived Hash into a verifying HashedCredential' do
      resolved = subject.resolve(record)
      expect(resolved).to be_a(IPaaS::Encryption::HashedCredential)
      expect(resolved.verify(plaintext)).to be(true)
    end

    it 'does not derive from a raw plaintext String' do
      resolved = subject.resolve(plaintext)
      expect(resolved).not_to be_a(IPaaS::Encryption::HashedCredential)
      expect(resolved).to eq(plaintext)
    end

    it 'never raises on a malformed-but-shaped record and returns it unchanged' do
      bad_base64 = { 'salt' => 'not base64!!', 'hash' => record['hash'] }
      wrong_length = { 'salt' => Base64.strict_encode64('short'), 'hash' => record['hash'] }

      expect(subject.resolve(bad_base64)).to eq(bad_base64)
      expect(subject.resolve(bad_base64)).not_to be_a(IPaaS::Encryption::HashedCredential)
      expect(subject.resolve(wrong_length)).to eq(wrong_length)
      expect(subject.resolve(wrong_length)).not_to be_a(IPaaS::Encryption::HashedCredential)
    end
  end

  describe 'valid?' do
    it 'is true for blank values' do
      expect(subject.valid?(nil)).to be(true)
      expect(subject.valid?('')).to be(true)
    end

    it 'is true for a well-formed derived Hash and for a resolved HashedCredential object' do
      expect(subject.valid?(record)).to be(true)
      expect(subject.valid?(subject.resolve(record))).to be(true)
    end

    it 'is false with an explanatory error for a bare String or number' do
      string_errors = []
      number_errors = []
      expect(subject.valid?('Hello Moon!', string_errors)).to be(false)
      expect(subject.valid?(42, number_errors)).to be(false)
      expect(string_errors).to eq(['Expected a derived hashed-credential value (…salt/hash…).'])
      expect(number_errors).to eq(['Expected a derived hashed-credential value (…salt/hash…).'])
    end

    it 'is false for a resolved object whose to_h fails the strict gate (bad Base64 / wrong length)' do
      bad_base64 = subject.resolve({ 'salt' => 'not base64!!', 'hash' => record['hash'] })
      wrong_length = subject.resolve({ 'salt' => Base64.strict_encode64('short'), 'hash' => record['hash'] })

      expect(subject.valid?(bad_base64)).to be(false)
      expect(subject.valid?(wrong_length)).to be(false)
    end

    it 'is false for a raw Hash whose salt/hash is non-strict-Base64 or wrong length, without echoing material' do
      bad_base64 = { 'salt' => 'not base64!!', 'hash' => record['hash'] }
      wrong_length = { 'salt' => Base64.strict_encode64('short'), 'hash' => record['hash'] }
      bad_base64_errors = []
      wrong_length_errors = []

      expect(subject.valid?(bad_base64, bad_base64_errors)).to be(false)
      expect(subject.valid?(wrong_length, wrong_length_errors)).to be(false)
      [bad_base64_errors, wrong_length_errors].each do |errors|
        expect(errors.join).not_to include(record['salt'])
        expect(errors.join).not_to include(record['hash'])
      end
    end
  end

  describe 'example' do
    it 'returns a canonical salt/hash record that passes the strict validator' do
      field = IPaaS::Connector::Schema::Field.new(id: :foo, label: 'Foo', type: :hashed_credential)
      example = subject.example(field)
      expect(example.keys).to eq(%w[salt hash])
      expect { IPaaS::Encryption::HashedCredential.from_h!(example) }.not_to raise_error
    end
  end

  describe 'schema' do
    it 'declares the salt and hash sub-fields, hidden from manual mapping' do
      expect(subject.schema.fields.map(&:id)).to eq([:salt, :hash])
      expect(subject.schema.fields.map(&:visibility)).to all(eq('hidden'))
    end
  end

  describe 'YAML round-trip' do
    it 'survives Serializer.parse of a dumped record and re-wraps into a verifying HashedCredential' do
      round_tripped = IPaaS::Connector::Common::Serializer.parse(YAML.dump(record))
      resolved = subject.resolve(round_tripped)
      expect(resolved).to be_a(IPaaS::Encryption::HashedCredential)
      expect(resolved.verify(plaintext)).to be(true)
    end
  end

  # The real resolve→type-check→valid? path (resolved_mapping.rb:53-55, 217-224,
  # 389-395): a shaped record is already a HashedCredential OBJECT by the time
  # valid? runs, so the object case is the one that must be re-checked strictly.
  describe 'through ResolvedMapping' do
    let(:schema) do
      IPaaS::Connector::Schema.new('reference') do
        field :secret, 'Secret', :hashed_credential,
              required: true
      end
    end

    def resolve(field_mapping)
      IPaaS::Connector::Mapping::ResolvedMapping.new(Object.new, schema.fields, field_mapping).resolve
    end

    it 'validates a well-formed derived record true and resolves it to a verifying HashedCredential' do
      resolved = resolve([{ field_id: :secret, fixed: record }])
      expect(resolved).to be_valid
      expect(resolved[:secret]).to be_a(IPaaS::Encryption::HashedCredential)
      expect(resolved[:secret].verify(plaintext)).to be(true)
    end

    # A malformed FIXED Hash: from_h! raises in resolve, so resolve returns the
    # raw Hash and the is_a?(ruby_class) type check (which runs before valid?)
    # rejects it. No exception, no material echo.
    it 'invalidates a malformed fixed record via the type check without raising or echoing material' do
      bad_base64 = { 'salt' => 'not base64!!', 'hash' => record['hash'] }
      wrong_length = { 'salt' => Base64.strict_encode64('short'), 'hash' => record['hash'] }

      [bad_base64, wrong_length].each do |malformed|
        resolved = nil
        expect { resolved = resolve([{ field_id: :secret, fixed: malformed }]) }.not_to raise_error
        expect(resolved).not_to be_valid
        errors = resolved.errors[:base].join
        expect(errors).to be_present
        expect(errors).not_to include(record['hash'])
      end
    end

    # A malformed HashedCredential OBJECT (e.g. built by the tolerant reader on the
    # env-var path) is already the ruby_class, so it passes the type check and
    # valid? must re-check its content strictly — surfacing the salt/hash message.
    it 'invalidates a malformed resolved object via valid? without raising or echoing material' do
      tolerant_object = IPaaS::Encryption::HashedCredential.from_h(
        'salt' => Base64.strict_encode64('short'), 'hash' => record['hash']
      )
      resolved = nil
      expect { resolved = resolve([{ field_id: :secret, fixed: tolerant_object }]) }.not_to raise_error
      expect(resolved).not_to be_valid
      errors = resolved.errors[:base].join
      expect(errors).to include('salt/hash')
      expect(errors).not_to include(record['hash'])
    end
  end
end
