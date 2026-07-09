require 'spec_helper'

# Every synced connector fixture must load and validate the same way the runtime
# loader does: evaluating the entrypoint returns a connector, which must be `valid?`.
# `rake connector:sync` copies the SDK fixtures here before the suite runs. A bare
# require only registers a fixture and never validates it, so an invalid fixture
# (e.g. a name shorter than the allowed minimum) went undetected. See request #77484427.
describe 'fixtures' do
  fixtures_dir = File.expand_path('../../fixtures/connectors', __dir__)
  fixture_files = Dir[File.join(fixtures_dir, '*.rb')]

  it 'has synced connector fixtures to validate' do
    expect(fixture_files).not_to be_empty
  end

  fixture_files.each do |file|
    it "loads and validates the #{File.basename(file, '.rb')} fixture" do
      connector = Module.new.module_eval(File.read(file), file)

      expect(connector).to be_a(IPaaS::Connector::Connector)
      expect(connector).to be_valid, -> { "#{connector.name}: #{connector.errors.full_messages.join(', ')}" }
    end
  end
end
