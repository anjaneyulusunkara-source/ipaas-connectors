require 'spec_helper'

describe 'fixture constants' do
  it 'leaves every constant a loaded fixture declares deeply immutable' do
    load_all_fixtures

    declared = fixture_classes.flat_map do |klass|
      klass.constants(false).map { |name| ["#{klass}::#{name}", Ractor.shareable?(klass.const_get(name))] }
    end

    # Every entrypoint must contribute a class, or the assertion below judges only what was found.
    expect(fixture_classes.map { |klass| Object.const_source_location(klass.name).first }.uniq.sort)
      .to eq(fixture_entrypoints('*').sort)
    expect(declared.reject(&:last)).to be_empty
  end

  # Object.const_source_location raises NameError, rather than returning nil, for a class defined
  # inside an anonymous module.
  it 'skips a definition class that has no resolvable name' do
    anonymous = Module.new
    anonymous.module_eval("class Unnamed < IPaaS::Connector::Definition; STUFF = ['x']; end", __FILE__, __LINE__)

    expect { fixture_classes }.not_to raise_error
    expect(fixture_classes).not_to include(anonymous.const_get(:Unnamed, false))
  end
end
