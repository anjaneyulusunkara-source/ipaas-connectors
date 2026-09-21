require 'spec_helper'

describe IPaaS::Connector::Common::YamlLimits do
  def nested(levels)
    "#{(0...levels).map { |level| "#{'  ' * level}a:" }.join("\n")} 1\n"
  end

  describe '.exceeded' do
    it 'reports nothing for content within both limits' do
      expect(described_class.exceeded(nested(3))).to be_nil
      expect(described_class.exceeded("a: #{'x' * 100}\n")).to be_nil
    end

    it 'reports the limit that is broken' do
      expect(described_class.exceeded("a: #{'x' * described_class::MAX_BYTES}\n")).to eq(:size)
      expect(described_class.exceeded(nested(described_class::MAX_DEPTH + 1))).to eq(:depth)
    end

    it 'accepts content sitting exactly on each limit, so the limit is the last size that fits' do
      on_size = "a: #{'x' * (described_class::MAX_BYTES - 4)}\n"

      on_depth = nested(described_class::MAX_DEPTH)

      expect(described_class.bytes(on_size)).to eq(described_class::MAX_BYTES)
      expect(described_class.depth(on_depth)).to eq(described_class::MAX_DEPTH)
      expect(described_class.exceeded(on_size)).to be_nil
      expect(described_class.exceeded(on_depth)).to be_nil
    end

    # Size costs no parse, so a file over it need not be parseable to be judged.
    it 'reports the size for over-size content it could not have measured the depth of' do
      unparseable_and_too_big = "a: [1\nb: #{'x' * described_class::MAX_BYTES}\n"

      expect { described_class.depth(unparseable_and_too_big) }.to raise_error(Psych::SyntaxError)
      expect(described_class.exceeded(unparseable_and_too_big)).to eq(:size)
    end
  end

  it 'names the kind itself when Exceeded has no wording for it' do
    expect(described_class::Exceeded.new(:mystery).message).to eq('mystery')
  end

  describe 'resistance to tampering' do
    it 'refuses a redefined judgement, a removed measurement, a relaxed limit and a silenced handler' do
      expect(described_class).to be_frozen
      expect(described_class::DepthHandler).to be_frozen
      expect { described_class.singleton_class.send(:define_method, :exceeded) { |_content| nil } }
        .to raise_error(FrozenError)
      expect { described_class.singleton_class.send(:undef_method, :depth) }.to raise_error(FrozenError)
      expect { described_class.send(:const_set, :MAX_BYTES, 1) }.to raise_error(FrozenError)
      # Left unfrozen, this route reports no depth at all rather than raising.
      expect { described_class::DepthHandler.send(:alias_method, :max, :end_mapping) }
        .to raise_error(FrozenError)
    end
  end

  describe '.bytes' do
    it 'counts bytes rather than characters, since the limit bounds what is stored' do
      expect(described_class.bytes('é')).to eq(2)
      expect(described_class.bytes('e')).to eq(1)
    end
  end

  describe '.depth' do
    it 'counts a flat mapping as one level and each nested collection as one more' do
      expect(described_class.depth("a: 1\n")).to eq(1)
      expect(described_class.depth(nested(3))).to eq(3)
    end

    it 'counts sequences and flow style the same as block mappings' do
      expect(described_class.depth("- - 1\n")).to eq(2)
      expect(described_class.depth("a: [{b: 1}]\n")).to eq(3)
    end

    it 'reports the deepest branch rather than the last one' do
      expect(described_class.depth("a:\n  b:\n    c: 1\nd:\n  e: 2\n")).to eq(3)
    end

    it 'counts no level for a document holding only a scalar, or nothing at all' do
      expect(described_class.depth("--- 1\n")).to eq(0)
      expect(described_class.depth('')).to eq(0)
    end

    # The read path loads only the first document, so a later one cannot be what breaks a load.
    it 'measures the first document only, whichever of the two is deeper' do
      shallow_then_deep = "--- 1\n--- #{'[' * 30}#{']' * 30}\n"
      deep_then_shallow = "--- #{'[' * 30}#{']' * 30}\n--- 1\n"

      expect(described_class.depth(shallow_then_deep)).to eq(0)
      expect(described_class.depth(deep_then_shallow)).to eq(30)
    end

    # Measured before anything tries to load it, so an aliased file still gets a figure.
    it 'counts an aliased subtree where it is written, not where it is referenced' do
      expect(described_class.depth("a: &deep\n  b:\n    c: 1\nd:\n  e:\n    f: *deep\n")).to eq(3)
    end

    # Flow style keeps the file small where block indentation would grow quadratically.
    it 'measures ten thousand levels of nesting' do
      very_deep = "#{'[' * 10_000}#{']' * 10_000}\n"

      expect(described_class.depth(very_deep)).to eq(10_000)
    end

    it 'raises for a document that will not parse, leaving the caller to report that once' do
      expect { described_class.depth("a: [1\n") }.to raise_error(Psych::SyntaxError)
    end

    it 'stops one level past a limit, and measures in full without one, as the sweep needs' do
      expect(described_class.depth(nested(10), limit: 3)).to eq(4)
      expect(described_class.depth(nested(10))).to eq(10)
    end

    # Reaching the end of this document raises, so a measurement that returns proves early exit.
    it 'stops before the end of the document, rather than measuring it in full' do
      unterminated_past_the_limit = "#{'[' * (described_class::MAX_DEPTH + 1)}1"

      expect { described_class.depth(unterminated_past_the_limit) }.to raise_error(Psych::SyntaxError)
      expect(described_class.depth(unterminated_past_the_limit, limit: described_class::MAX_DEPTH))
        .to eq(described_class::MAX_DEPTH + 1)
      expect(described_class.exceeded(unterminated_past_the_limit)).to eq(:depth)
    end
  end
end
