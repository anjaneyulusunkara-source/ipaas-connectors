require 'spec_helper'

describe IPaaS::Connector::Common::SourceParser do
  # Ripper reports an error through six channels, and four of them are generated as ordinary parser
  # events, so a source reaching one of those publishes a tree and reads as parseable unless the
  # channel is named. One shape per channel, kept together because the agreement sweep needs them.
  # A duplicated argument name is not the shape for on_param_error: that one reports through
  # compile_error, and only a parameter that is not a local reaches on_param_error.
  REFUSED_BY_RIPPER = [
    'def (',              # on_parse_error
    "'abc",               # compile_error
    'alias $a $1',        # on_alias_error
    'nil = 1',            # on_assign_error
    'class foo; end',     # on_class_name_error
    'def f($g); end',     # on_param_error
  ].freeze

  def read(source) = described_class.read(source)

  describe '.read' do
    it 'builds the tree Ripper would for a source that parses' do
      parsed = read("(1..10).to_a.join(', ')")

      expect(parsed.tree).to eq(Ripper.sexp("(1..10).to_a.join(', ')"))
      expect(parsed.diagnostic).to be_nil
    end

    # The builder hands back a partial tree for a source it could not parse, which would be
    # measured as if it were the whole source and let an unparseable body through.
    it 'publishes no tree for a source it could not parse' do
      parsed = read("mapping[\#{pill}]")

      expect(parsed.tree).to be_nil
      expect(parsed.diagnostic).to be_present
    end

    # Every fixture parses, so a shape Ripper refuses is compared alongside them: without one both
    # sides of the comparison are false for every input, and a tree published with no diagnostic —
    # which is what this example exists to catch — goes unnoticed.
    it 'agrees with Ripper on what has a tree, across every connector fixture and every refusal' do
      files = Dir.glob(File.expand_path('../../../fixtures/connectors/**/*.rb', __dir__))
      expect(files).not_to be_empty

      disagreeing = (files.map { |file| File.read(file) } + REFUSED_BY_RIPPER).reject do |source|
        read(source).tree.nil? == Ripper.sexp(source).nil?
      end
      expect(disagreeing).to be_empty
    end
  end

  describe '#comments' do
    it 'collects them from a source that parses' do
      expect(read("'a' # \#{pill}\n1 + 1").comments).to eq(["# \#{pill}\n"])
    end

    # Reading them off a source that will not parse is what keeps the data-pill message available
    # for a source refused on its parse.
    it 'collects them from a source that does not' do
      expect(read("mapping[\#{pill}]").comments).to eq(["\#{pill}]"])
    end

    it 'is empty when the source holds none' do
      expect(read('1 + 1').comments).to be_empty
    end
  end

  describe '#diagnostic' do
    # Two channels reach it: the parser's, and the lexer's for anything that never becomes a token.
    # The builder aliases both onto a method of its own, so hearing one says nothing about the other.
    {
      'an unterminated single quote' => ["'abc", /line 1: unterminated string meets end of file/],
      'an unterminated double quote' => ['"abc', /line 1: unterminated string meets end of file/],
      'an unterminated heredoc' => ["x = <<~SQL\n  select", /line 1: can't find string "SQL"/],
      'a syntax error' => ['def (', /line 1: syntax error/],
      'a duplicated argument' => ['def f(a, a); end', /line 1: duplicated argument name/],
      'an alias of a number variable' => ['alias $a $1', /line 1: can't make alias/],
      'an assignment to nil' => ['nil = 1', /line 1: Can't assign to nil/],
      'a lowercase class name' => ['class foo; end', %r{line 1: class/module name must be CONSTANT}],
      'a global as a parameter' => ['def f($g); end', /line 1: formal argument cannot be a global/],
      'a constant as a block parameter' => ['[1].each { |FOO| }', /line 1: formal argument cannot be/],
    }.each do |label, (source, complaint)|
      it "reports #{label} in the parser's own words" do
        expect(read(source).diagnostic).to match(complaint)
      end
    end

    it 'names the line the complaint came from, not the first' do
      expect(read("1 + 1\n2 + 2\ndef (").diagnostic).to match(/\Aline 3:/)
    end

    # Two duplicated-argument defs each publish a complaint, where two `def (` produce only one, so
    # only this shape can tell the first complaint from the last.
    it 'keeps the first complaint when a source produces several' do
      expect(read("def f(a, a); end\ndef g(b, b); end").diagnostic).to eq('line 1: duplicated argument name')
    end

    # Ripper raises rather than returning for an encoding that does not exist, and says so over
    # three lines, which a caller appending its own punctuation cannot use.
    it 'reports an encoding that does not exist, on one line' do
      parsed = read("# encoding: not-a-real-encoding\n1 + 1")

      expect(parsed.diagnostic).to eq('unknown encoding name: not-a-real-encoding')
      expect(parsed.tree).to be_nil
    end

    it 'is nil for an encoding that does exist' do
      expect(read("# encoding: utf-8\n1 + 1").diagnostic).to be_nil
    end

    # Which complaint travels which channel is Ripper's business and changes between releases, so
    # the cover is pinned structurally: a release that adds an error event fails here rather than
    # going quiet. `compile_error` is a hook rather than an event, so it is named separately.
    it 'names every error channel Ripper publishes' do
      unnamed = (Ripper::PARSER_EVENT_TABLE.keys.grep(/error/).map { |event| :"on_#{event}" } + [:compile_error])
                .reject { |hook| described_class.instance_method(hook).owner == described_class }

      expect(unnamed).to be_empty
    end

    it 'publishes no tree for any shape Ripper refuses, whichever channel reported it' do
      published = REFUSED_BY_RIPPER.select { |source| read(source).tree }

      expect(published).to be_empty
    end
  end
end
