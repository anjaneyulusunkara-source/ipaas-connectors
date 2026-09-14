require 'spec_helper'

describe IPaaS::Connector::Definition do
  describe 'Permissions definition' do
    it 'should not allow multiple connections in a single class' do
      expect do
        Class.new(IPaaS::Connector::Definition) do
          connector 'foo' do
          end
          connector 'bar' do
          end
        end
      end.to raise_exception('Only one connector per class allowed')
    end

    it 'allows multiple classes with connections' do
      Class.new(IPaaS::Connector::Definition) do
        connector 'foo' do |c|
          c.name 'foo-fie'
        end
      end
      Class.new(IPaaS::Connector::Definition) do
        connector 'bar' do |c|
          c.name 'barbie'
        end
      end
      expect(IPaaS::Connector.by_uuid('foo').name).to eq('foo-fie')
      expect(IPaaS::Connector.by_uuid('bar').name).to eq('barbie')
    end

    it 'disallows multiple classes with connection with the same uuid' do
      Class.new(IPaaS::Connector::Definition) do
        connector 'foo' do |c|
          c.name 'foo-fie'
        end
      end
      expect do
        Class.new(IPaaS::Connector::Definition) do
          connector 'foo' do |c|
          end
        end
      end.to raise_exception('Duplicate Connector UUID: foo, in default scope.')
      expect(IPaaS::Connector.by_uuid('foo').name).to eq('foo-fie')
    end
  end

  describe '.make_constants_shareable' do
    it 'makes a constant deeply immutable, including members the author left mutable' do
      klass = Class.new(IPaaS::Connector::Definition)
      klass.const_set(:WORDS, %w[a b].freeze)
      # `.freeze` freezes the array, not the strings in it.
      expect(Ractor.shareable?(klass.const_get(:WORDS))).to be(false)

      described_class.make_constants_shareable(klass)

      expect(Ractor.shareable?(klass.const_get(:WORDS))).to be(true)
      expect(klass.const_get(:WORDS).first).to be_frozen
    end

    it 'reaches hash keys and nested collections, not just the outermost value' do
      klass = Class.new(IPaaS::Connector::Definition)
      klass.const_set(:NESTED, { %w[key] => { inner: ['deep'] } })

      described_class.make_constants_shareable(klass)

      value = klass.const_get(:NESTED)
      expect(value.keys.first.first).to be_frozen
      expect(value.values.first[:inner].first).to be_frozen
    end

    it 'leaves a module a connector merely names unfrozen' do
      klass = Class.new(IPaaS::Connector::Definition)
      klass.const_set(:GqlSchema, IPaaS::Job::GraphQL::Schema)
      klass.const_set(:SCHEMAS, [IPaaS::Job::GraphQL::Schema])
      klass.const_set(:BY_NAME, { 'schema' => IPaaS::Job::GraphQL::Schema })

      described_class.make_constants_shareable(klass)

      # Freezing a module the connector only names is an irreversible, process-wide change to code
      # it does not own.
      expect(IPaaS::Job::GraphQL::Schema).not_to be_frozen
      expect(Ractor.shareable?(klass.const_get(:SCHEMAS))).to be(true)
      expect(Ractor.shareable?(klass.const_get(:BY_NAME))).to be(true)
    end

    it 'freezes the constants of the class it was given, not those of another' do
      declared = Class.new(IPaaS::Connector::Definition)
      declared.const_set(:MINE, ['mine'])
      other = Class.new(IPaaS::Connector::Definition)
      other.const_set(:THEIRS, ['theirs'])

      described_class.make_constants_shareable(declared)

      expect(Ractor.shareable?(declared.const_get(:MINE))).to be(true)
      expect(Ractor.shareable?(other.const_get(:THEIRS))).to be(false)
    end

    it 'lists the constants through Module, so an overriding class cannot shorten the list' do
      klass = Class.new(IPaaS::Connector::Definition) do
        def self.constants(*) = []
      end
      klass.const_set(:HIDDEN, ['hidden'])

      described_class.make_constants_shareable(klass)

      expect(Ractor.shareable?(Module.instance_method(:const_get).bind_call(klass, :HIDDEN))).to be(true)
    end

    it 'reads the values through Module, so an overriding class cannot substitute one' do
      klass = Class.new(IPaaS::Connector::Definition) do
        def self.const_get(*) = nil
      end
      klass.const_set(:SWAPPED, ['swapped'])

      described_class.make_constants_shareable(klass)

      expect(Ractor.shareable?(Module.instance_method(:const_get).bind_call(klass, :SWAPPED))).to be(true)
    end

    # inherit=false on both: a constant on a superclass belongs to whoever declared it.
    it 'leaves a constant it inherits from a parent class alone' do
      parent = Class.new(IPaaS::Connector::Definition)
      parent.const_set(:INHERITED, ['parent'])
      klass = Class.new(parent)
      klass.const_set(:OWN, ['own'])

      described_class.make_constants_shareable(klass)

      expect(Ractor.shareable?(klass.const_get(:OWN))).to be(true)
      expect(Ractor.shareable?(parent.const_get(:INHERITED))).to be(false)
    end

    # Source order is dependency order, so each value is walked with its references already
    # immutable and no walk descends further than one statement's own nesting. Unsorted, a chain of
    # back-references is one walk as deep as the chain, which overflows a pooled thread's stack.
    # Pinned on the order rather than by overflowing: rescuing a SystemStackError arms the thread,
    # so the next one aborts the process, this suite's included.
    it 'walks the constants in source order, so a chain of back-references is never one deep walk' do
      klass = Class.new(IPaaS::Connector::Definition)
      # Assigned bottom-up, so the order the constant table reports is not the order of the lines.
      # rubocop:disable-next Style/DocumentDynamicEvalDefinition
      10.downto(1) { |line| klass.class_eval("C#{line} = ['#{line}']", __FILE__, line) }
      source_order = (1..10).map { |line| :"C#{line}" }
      # Without a divergence the assertion below would hold for an unsorted walk too.
      expect(Module.instance_method(:constants).bind_call(klass, false)).not_to eq(source_order)
      expected = source_order.map { |name| klass.const_get(name, false).object_id }

      walked = []
      allow(IPaaS).to receive(:make_shareable).and_wrap_original do |original, value|
        walked << value
        original.call(value)
      end

      described_class.make_constants_shareable(klass)

      expect(walked.map(&:object_id)).to eq(expected)
    end

    # Fail closed. The shape check refuses proc-valued constants, so only some future unfreezable
    # value reaches this.
    it 'raises on a value it cannot make immutable rather than leaving it mutable' do
      captured = 'outer'
      klass = Class.new(IPaaS::Connector::Definition)
      klass.const_set(:CALLABLE, [-> { captured }])

      expect { described_class.make_constants_shareable(klass) }.to raise_error(Ractor::IsolationError)
    end
  end
end
