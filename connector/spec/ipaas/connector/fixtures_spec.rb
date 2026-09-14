require 'spec_helper'

# Every synced connector fixture must load and validate the same way the runtime
# loader does: evaluating the entrypoint returns a connector, which must be `valid?`.
# `rake connector:sync` copies the SDK fixtures here before the suite runs. A bare
# require only registers a fixture and never validates it, so an invalid fixture
# (e.g. a name shorter than the allowed minimum) went undetected. See request #77484427.
describe 'fixtures' do
  fixtures_dir = File.expand_path('../../fixtures/connectors', __dir__)
  fixture_files = Dir[File.join(fixtures_dir, '*.rb')]

  def definition_classes(definitions)
    definitions.constants(false).map { |name| definitions.const_get(name, false) }
  end

  it 'has synced connector fixtures to validate' do
    expect(fixture_files).not_to be_empty
  end

  it 'makes every constant the synced fixtures declare deeply immutable' do
    before_freeze = []
    after_freeze = []
    files_with_classes = 0

    fixture_files.each do |file|
      definitions = Module.new
      definitions.module_eval(File.read(file), file)
      classes = definition_classes(definitions)
      files_with_classes += 1 if classes.any?
      classes.each do |klass|
        names = klass.constants(false)
        before_freeze.concat(names.map { |name| Ractor.shareable?(klass.const_get(name)) })
        IPaaS::Connector::Definition.make_constants_shareable(klass)
        after_freeze.concat(names.map { |name| [file, name, Ractor.shareable?(klass.const_get(name))] })
      end
    end

    # Two ways the corpus could stop exercising the freeze: fixtures stopping short of a definition
    # class, and a corpus with nothing mutable left in it.
    expect(files_with_classes).to eq(fixture_files.size)
    expect(before_freeze.count(false)).to be >= 5
    expect(after_freeze.reject(&:last)).to be_empty
  end

  fixture_files.each do |file|
    it "connector #{File.basename(file, '.rb')} does not exceed the loadable source size" do
      expect(File.size(file)).to be <= IPaaS::Connector::Connector::MAX_SOURCE_FILE_BYTES
    end

    it "still validates the #{File.basename(file, '.rb')} fixture once its constants are frozen" do
      definitions = Module.new
      connector = definitions.module_eval(File.read(file), file)
      definition_classes(definitions).each { |klass| IPaaS::Connector::Definition.make_constants_shareable(klass) }

      expect(connector).to be_a(IPaaS::Connector::Connector)
      expect(connector).to be_valid, -> { "#{connector.name}: #{connector.errors.full_messages.join(', ')}" }
    end

    it "keeps the #{File.basename(file, '.rb')} fixture inside the declared shape" do
      outcome = IPaaS::Connector::Common::LoadRules::ConnectorShape.check(File.read(file), file)

      expect(outcome).to be_checked, -> { "#{file}: #{outcome.uncheckable}" }
      expect(outcome).to be_in_shape, -> { "#{file}: #{outcome.findings.join('; ')}" }
    end
  end

  it 'refuses a source outside the shape, so the assertions above can fail' do
    outcome = IPaaS::Connector::Common::LoadRules::ConnectorShape.check(<<~RUBY, 'control')
      class Control < IPaaS::Connector::Definition
        SNEAKED = File.write('/tmp/control', 'x')
        connector 'uuid' do
          name 'Control'
        end
      end
    RUBY

    expect(outcome.findings).to eq(["assigns 'SNEAKED' a value that is not a constant expression"])
  end
end
