require 'spec_helper'

describe IPaaS::Connector::Common::Serializer do
  it 'should parse a YAML string' do
    expect(subject.class.parse('foo: bar')).to eq({ 'foo' => 'bar' })
  end

  it 'should parse a YAML string and add UUID if requested' do
    result = subject.class.parse('foo: bar', with_uuid: true)
    expect(result['foo']).to eq('bar')
    expect(result['uuid']).to be_present
    expect(result.keys).to contain_exactly('foo', 'uuid')
  end

  it 'should add a UUID to a YAML string if requested' do
    result = subject.class.parse('foo: bar', with_uuid: true)
    expect(result['foo']).to eq('bar')
    expect(result['uuid']).to be_present
    expect(result.keys).to contain_exactly('foo', 'uuid')
  end

  it 'should add a UUID to a hash if requested' do
    result = subject.class.parse({ foo: :baz }, with_uuid: true)
    expect(result[:foo]).to eq(:baz)
    expect(result['uuid']).to be_present
    expect(result.keys).to contain_exactly(:foo, 'uuid')
  end

  it 'should not add a UUID to a hash if already present as string' do
    result = subject.class.parse({ foo: :baz, 'uuid' => 'sadasd' }, with_uuid: true)
    expect(result[:foo]).to eq(:baz)
    expect(result['uuid']).to eq('sadasd')
    expect(result.keys).to contain_exactly(:foo, 'uuid')
  end

  it 'should not add a UUID to a hash if already present as symbol' do
    result = subject.class.parse({ foo: :baz, uuid: 'sadasd' }, with_uuid: true)
    expect(result[:foo]).to eq(:baz)
    expect(result[:uuid]).to eq('sadasd')
    expect(result.keys).to contain_exactly(:foo, :uuid)
  end

  it 'should return the value when it is not a string' do
    expect(subject.class.parse(:foo)).to eq(:foo)
  end

  it 'should parse a Regexp value' do
    expect(subject.class.parse('default: !ruby/regexp /\d+/')).to eq({ 'default' => /\d+/ })
  end

  it 'should parse a YAML file' do
    file = Tempfile.new(%w[my-file .yaml])
    begin
      uuid = SecureRandom.uuid_v7
      file << "uuid: #{uuid}"
      file.close

      f = File.new(file.path)
      expect(subject.class.parse(f, with_uuid: true)).to eq({ 'uuid' => uuid })
    ensure
      file.close!
    end
  end

  it 'should not default uuid when parsing a YAML file unless requested' do
    file = Tempfile.new(%w[my-file .yaml])
    begin
      file << 'foo: baz'
      file.close

      f = File.new(file.path)
      expect(subject.class.parse(f)).to eq({ 'foo' => 'baz' })
    ensure
      file.close!
    end
  end

  it 'should default uuid when parsing a YAML file if requested' do
    file = Tempfile.new(%w[my-file .yaml])
    begin
      file << 'foo: baz'
      file.close

      f = File.new(file.path)
      expect(subject.class.parse(f,
                                 with_uuid: true)).to eq({ 'foo' => 'baz',
                                                           'uuid' => File.basename(file.path, '.yaml'), })
    ensure
      file.close!
    end
  end

  it 'should default uuid when parsing a YML file if requested' do
    file = Tempfile.new(%w[my-file2 .yml])
    begin
      file << 'foo: baz'
      file.close

      f = File.new(file.path)
      expect(subject.class.parse(f,
                                 with_uuid: true)).to eq({ 'foo' => 'baz', 'uuid' => File.basename(file.path, '.yml') })
    ensure
      file.close!
    end
  end

  context 'a SecretString written by an older release' do
    let(:stored) do
      "---\n:id: :api_key\n:label: API Key\n:type: :secret_string\n" \
        ":default: !ruby/object:IPaaS::Encryption::SecretString\n  encrypted: gAAAA_blob==\n  encryptor:\n"
    end
    let(:field) { IPaaS::Connector::Schema::Field.new(**subject.class.parse(stored)) }

    it 'loads under strict parsing, keeps the ciphertext, and validates' do
      expect(field.default).to be_a(IPaaS::Encryption::SecretString)
      expect(field.default.encrypted).to eq('gAAAA_blob==')
      expect(field).to be_valid
    end

    it 'rewrites it to the untagged form on the next save' do
      dumped = field.to_h_ref.to_yaml

      expect(dumped).not_to include('!ruby/object:')
      expect(dumped).to include('gAAAA_blob==')
    end
  end

  context 'tolerant loading' do
    after { described_class.reset_tolerant_substitution! }

    let(:unpermitted) { UnresolvedNodeHelper::UNPERMITTED_CLASS }
    let(:yaml_with_unpermitted) { "---\nname: rb\n#{unpermitted_mapping_yaml(key: 'value')}" }

    it 'raises on an unpermitted class when not tolerant' do
      expect { subject.class.parse(yaml_with_unpermitted) }
        .to raise_error(Psych::DisallowedClass, /#{unpermitted}/)
    end

    it 'substitutes an UnresolvedNode when tolerant and re-emits it byte-for-byte on save' do
      result = subject.class.parse(yaml_with_unpermitted, tolerant: true)
      expect(result['name']).to eq('rb')
      expect(result['value']).to be_a(IPaaS::Connector::Common::UnresolvedNode)
      expect(result['value'].unresolved_class).to eq(unpermitted)
      expect(subject.class.dump(result)).to eq(yaml_with_unpermitted)
    end

    it 'ignores documents after the first, as strict loading does' do
      trailing_junk = "#{unpermitted_mapping_yaml}---\nbroken: [1, 2\n"

      expect { subject.class.parse(trailing_junk) }.to raise_error(Psych::DisallowedClass)
      expect(subject.class.parse(trailing_junk, tolerant: true)['v'])
        .to be_a(IPaaS::Connector::Common::UnresolvedNode)
    end

    ['', "# only a comment\n", "---\n"].each do |content|
      it "returns nil for #{content.inspect} rather than failing to walk the stream" do
        expect(subject.class.parse(content, tolerant: true)).to be_nil
      end
    end

    it 'still parses a permitted Regexp on the tolerant path' do
      expect(subject.class.parse('default: !ruby/regexp /\d+/', tolerant: true)).to eq({ 'default' => /\d+/ })
    end

    it 'rejects a YAML alias outside the captured node, matching strict loading' do
      aliased = "z: !ruby/object:#{unpermitted} {}\na: &a [x]\nb: [*a]\n"
      expect { subject.class.parse(aliased, tolerant: true) }.to raise_error(Psych::AliasesNotEnabled)
    end

    it 'rejects a YAML alias nested inside the captured node' do
      aliased = "a: &a [x]\nv: !ruby/object:#{unpermitted}\n  data: *a\n"
      expect { subject.class.parse(aliased, tolerant: true) }.to raise_error(Psych::AliasesNotEnabled)
    end

    it 'records that a substitution occurred only when one happened' do
      subject.class.reset_tolerant_substitution!
      subject.class.parse('foo: bar', tolerant: true)
      expect(subject.class.tolerant_substitution_occurred?).to be(false)

      subject.class.parse(yaml_with_unpermitted, tolerant: true)
      expect(subject.class.tolerant_substitution_occurred?).to be(true)
    end

    context 'a legacy secret whose encryptor is not permitted' do
      let(:legacy_secret_yaml) do
        "value: !ruby/object:IPaaS::Encryption::SecretString\n  " \
          "encrypted: gAAAA_blob==\n  " \
          "encryptor: !ruby/object:IPaaS::Encryption::Encryptor\n    " \
          "key: k\n"
      end

      it 'loads the secret and keeps no placeholder in the result' do
        result = subject.class.parse(legacy_secret_yaml, tolerant: true)

        expect(result['value']).to be_a(IPaaS::Encryption::SecretString)
        expect(result['value'].encrypted).to eq('gAAAA_blob==')
        expect(result['value'].encryptor).to be_nil
        expect(IPaaS::Connector::Common::UnresolvedNode.within?(result)).to be(false)
      end

      it 'records no substitution, because the placeholder never survived the load' do
        subject.class.reset_tolerant_substitution!

        subject.class.parse(legacy_secret_yaml, tolerant: true)

        expect(subject.class.tolerant_substitution_occurred?).to be(false)
      end
    end

    {
      'a Complex mapping' => "v: !ruby/object:Complex\n  real: 1\n  image: 2\n",
      'a Complex scalar' => "v: !ruby/object:Complex 1+2i\n",
      'a Rational mapping' => "v: !ruby/object:Rational\n  numerator: 1\n  denominator: 3\n",
      'a Rational scalar' => "v: !ruby/object:Rational 1/3\n",
      'a BigDecimal' => "v: !ruby/object:BigDecimal '0:0.1e1'\n",
      'a Ruby class reference' => "v: !ruby/class File\n",
      'a Ruby module reference' => "v: !ruby/module Kernel\n",
      'a Range' => "v: !ruby/range 1..5\n",
      'an Exception' => "v: !ruby/exception\n  message: boom\n",
      'a Struct' => "v: !ruby/struct\n  a: 1\n",
      'a String subclass' => "v: !ruby/string:MyStr hello\n",
      'a tagged sequence' => "v: !ruby/array:MyArr\n- 1\n- 2\n",
    }.each do |description, yaml|
      it "does not materialize #{description} on the tolerant path" do
        expect { subject.class.parse(yaml) }.to raise_error(Psych::DisallowedClass)

        value = subject.class.parse(yaml, tolerant: true)['v']
        expect(value).to be_a(IPaaS::Connector::Common::UnresolvedNode)
      end

      it "keeps the tag and payload of #{description} byte-for-byte across a save" do
        dumped = subject.class.dump(subject.class.parse(yaml, tolerant: true)).delete_prefix("---\n")

        expect(dumped).to eq(yaml)
        expect(subject.class.parse(dumped, tolerant: true)['v'])
          .to be_a(IPaaS::Connector::Common::UnresolvedNode)
      end
    end
  end

  context 'to_h' do
    it 'should create a hash with all attributes' do
      expect(subject.class.to_h(double(foo: 'a', bar: 1), :foo, :bar)).to eq({ foo: 'a', bar: 1 })
    end

    it 'should create a hash with selected attributes' do
      expect(subject.class.to_h(double(foo: 'a', bar: 1), :bar)).to eq({ bar: 1 })
    end

    it 'should add nested attributes' do
      expect(subject.class.to_h(double(foo: double(to_h_ref: 'nested')), :foo)).to eq({ foo: 'nested' })
    end

    it 'should add array nested attributes' do
      expect(subject.class.to_h(double(foo: [double(to_h_ref: 1), double(to_h_ref: 2)]), :foo)).to eq({ foo: [1, 2] })
    end

    context 'a placeholder sharing an array with a healthy field' do
      let(:healthy) { IPaaS::Connector::Schema::Field.new(id: :ok, label: 'OK', type: :string) }

      it 'dereferences the healthy field when the placeholder is ahead of it' do
        node = unresolved_node
        result = subject.class.to_h(double(fields: [node, healthy]), :fields)

        expect(result[:fields].first).to be(node)
        expect(result[:fields].last).to eq({ id: :ok, label: 'OK', type: :string })
      end

      it 'dereferences the healthy field when the placeholder is behind it' do
        node = unresolved_node
        result = subject.class.to_h(double(fields: [healthy, node]), :fields)

        expect(result[:fields].first).to eq({ id: :ok, label: 'OK', type: :string })
        expect(result[:fields].last).to be(node)
      end

      it 'writes the healthy field as a plain mapping rather than a native object tag' do
        dumped = subject.class.dump(subject.class.to_h(double(fields: [unresolved_node, healthy]), :fields))

        expect(dumped).not_to include('!ruby/object:IPaaS::Connector::Schema::Field')
        expect(dumped).to include('gAAAA_blob==')
      end
    end
  end

  context 'dump' do
    it 'refuses to write a class it could not read back' do
      expect { subject.class.dump({ 'v' => Legacy::RemovedSecret.new('gAAAA_blob==') }) }
        .to raise_error(IPaaS::Error, /Legacy::RemovedSecret/)
    end

    it 'writes a permitted class that defines encode_with' do
      dumped = subject.class.dump({ 'v' => IPaaS::Encryption::SecretString.new('cipher') })

      expect(dumped).to include('cipher')
    end
  end
end
