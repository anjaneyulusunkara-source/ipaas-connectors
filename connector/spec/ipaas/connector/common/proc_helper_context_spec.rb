require 'spec_helper'

ProcHelperContextDouble = Struct.new(:name) do
  def identify
    name
  end
end

describe IPaaS::Connector::Common::ProcHelper do
  let(:context_a) { ProcHelperContextDouble.new('A') }
  let(:context_b) { ProcHelperContextDouble.new('B') }

  def helper_for(context, procedure)
    described_class.new(context, procedure).tap do |helper|
      helper.define_singleton_method(:valid?) { true }
    end
  end

  describe 'context resolution' do
    it 'runs against its declared context' do
      expect(helper_for(context_a, proc { identify }).execute).to eq('A')
    end

    it 'inherits the context of the outermost proc executing on this thread' do
      inner = helper_for(nil, proc { identify })
      expect(helper_for(context_a, proc { inner.execute }).execute).to eq('A')
    end

    it 'resolves independently for each caller of one shared instance' do
      inner = helper_for(nil, proc { identify })

      expect(helper_for(context_a, proc { inner.execute }).execute).to eq('A')
      expect(helper_for(context_b, proc { inner.execute }).execute).to eq('B')
      expect(helper_for(context_a, proc { inner.execute }).execute).to eq('A')
    end

    it 'never writes the context onto the shared instance' do
      inner = helper_for(nil, proc { identify })

      helper_for(context_a, proc { inner.execute }).execute

      expect(inner.declared_context).to be_nil
    end

    it 'keeps a declared context when nested inside another context' do
      inner = helper_for(context_b, proc { identify })
      expect(helper_for(context_a, proc { inner.execute }).execute).to eq('B')
    end
  end

  describe 'concurrency' do
    it 'gives each thread its own context for one shared helper' do
      shared = helper_for(nil, proc { identify })
      barrier = Queue.new
      results = Queue.new

      threads = [[context_a, 'A'], [context_b, 'B']].map do |context, _expected|
        Thread.new do
          outer = helper_for(context, proc do
            barrier.pop
            shared.execute
          end)
          results << [context.identify, outer.execute]
        end
      end

      2.times { barrier << :go }
      threads.each { |thread| thread.join(20) }

      observed = {}
      observed.store(*results.pop) until results.empty?

      expect(observed).to eq('A' => 'A', 'B' => 'B')
      expect(shared.declared_context).to be_nil
    end

    it 'keeps contexts separate across many interleaved threads' do
      shared = helper_for(nil, proc { identify })
      results = Queue.new

      threads = Array.new(12) do |index|
        name = index.even? ? 'A' : 'B'
        Thread.new do
          context = ProcHelperContextDouble.new(name)
          outer = helper_for(context, proc { shared.execute })
          results << [name, outer.execute]
        end
      end
      threads.each { |thread| thread.join(20) }

      pairs = []
      pairs << results.pop until results.empty?

      expect(pairs).to all(satisfy { |expected, actual| expected == actual })
      expect(shared.declared_context).to be_nil
    end
  end

  describe 'thread state after failure' do
    it 'leaves no frame behind when a proc raises' do
      helper = helper_for(context_a, proc { raise ArgumentError, 'boom' })

      expect { helper.execute }.to raise_error(ArgumentError)
      expect(Thread.current[:executing_procs]).to be_empty
    end

    it 'leaves no frame behind when a nested proc raises' do
      inner = helper_for(nil, proc { raise ArgumentError, 'boom' })
      outer = helper_for(context_a, proc { inner.execute })

      expect { outer.execute }.to raise_error(ArgumentError)
      expect(Thread.current[:executing_procs]).to be_empty
    end

    it 'still resolves the next call correctly after a raise' do
      inner = helper_for(nil, proc { identify })
      raising = helper_for(nil, proc { raise ArgumentError, 'boom' })

      expect { helper_for(context_b, proc { raising.execute }).execute }.to raise_error(ArgumentError)
      expect(helper_for(context_a, proc { inner.execute }).execute).to eq('A')
    end
  end

  describe 'procedure forms' do
    it 'evaluates a String procedure' do
      expect(helper_for(context_a, 'identify').execute).to eq('A')
    end

    it 'evaluates a String procedure taking parameters' do
      expect(helper_for(context_a, '->(suffix) { identify + suffix }').execute('!')).to eq('A!')
    end

    it 'evaluates a Proc procedure taking parameters' do
      expect(helper_for(context_a, proc { |suffix| identify + suffix }).execute('!')).to eq('A!')
    end

    it 'evaluates a String procedure against an inherited context' do
      inner = helper_for(nil, 'identify')
      expect(helper_for(context_b, proc { inner.execute }).execute).to eq('B')
    end
  end

  describe 'validation errors' do
    it 'gives each thread back the errors it wrote on one shared instance' do
      helper = described_class.new(context_a, '1 + 1')
      seen = Queue.new

      threads = Array.new(8) do |index|
        Thread.new do
          helper.errors = ["thread-#{index}"]
          10.times { Thread.pass }
          seen << [index, helper.errors]
        end
      end
      threads.each { |thread| thread.join(20) }

      pairs = []
      pairs << seen.pop until seen.empty?

      expect(pairs.size).to eq(8)
      expect(pairs).to all(satisfy { |index, errors| errors == ["thread-#{index}"] })
    end

    it 'keeps errors separate per helper, so a validator can collect them across several' do
      first = described_class.new(context_a, '1 + 1')
      second = described_class.new(context_a, '2 + 2')

      first.errors = ['first']
      second.errors = ['second']

      expect([first.errors, second.errors]).to eq([['first'], ['second']])
    end

    it 'stores errors in a weak-keyed structure, so a helper is not pinned by the thread' do
      described_class.new(context_a, '1 + 1').valid?

      expect(Thread.current[:proc_helper_errors]).to be_a(ObjectSpace::WeakKeyMap)
    end
  end
end
