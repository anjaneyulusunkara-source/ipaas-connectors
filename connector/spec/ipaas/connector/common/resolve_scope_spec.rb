require 'spec_helper'

RSpec.describe IPaaS::Connector::Common::ResolveScope do
  after { described_class.reset }

  it 'reads back a value stamped in the same scope' do
    entry = described_class.stamp('boom')

    expect(described_class.read(entry)).to eq('boom')
  end

  it 'hides a value from a later scope on the same thread' do
    entry = described_class.stamp('boom')
    described_class.reset

    expect(described_class.read(entry)).to be_nil
  end

  it 'hides a value from another thread, which has its own scope' do
    entry = described_class.stamp('boom')

    expect(Thread.new { described_class.read(entry) }.value).to be_nil
  end

  it 'stamps nil as nil rather than as an entry carrying nil' do
    expect(described_class.stamp(nil)).to be_nil
    expect(described_class.read(nil)).to be_nil
  end
end

RSpec.describe 'resolve_error scoping on a model' do
  let(:connection) { IPaaS::Connector::Connection.new(SecureRandom.uuid) }

  after { IPaaS::Connector::Common::ResolveScope.reset }

  it 'is readable in the scope that recorded it' do
    connection.resolve_error = 'the field logic raised'

    expect(connection.resolve_error).to eq('the field logic raised')
  end

  # These records are handed out by a process-global cache with no deep copy.
  it 'is invisible to the next unit of work holding the same record' do
    connection.resolve_error = 'the field logic raised'
    IPaaS::Connector::Common::ResolveScope.reset

    expect(connection.resolve_error).to be_nil
  end
end
