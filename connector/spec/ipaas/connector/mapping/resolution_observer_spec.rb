require 'spec_helper'

# The platform installs a block-taking observer so a wall-clock guard firing mid-proc can name what it
# interrupted. The gem owns the contract, so the gem pins it.
RSpec.describe 'ResolvedMapping.tracking_resolution' do
  let(:described) { IPaaS::Connector::Mapping::ResolvedMapping }
  let(:context) { double(:context) }

  around do |example|
    previous = described.resolution_observer
    example.run
    described.resolution_observer = previous
  end

  it 'yields and returns the block value when no observer is installed' do
    described.resolution_observer = nil

    expect(described.tracking_resolution(context) { :resolved }).to eq(:resolved)
  end

  it 'passes the context to the observer and returns the block value through it' do
    seen = nil
    described.resolution_observer = ->(ctx, &block) {
      seen = ctx
      block.call
    }

    expect(described.tracking_resolution(context) { :resolved }).to eq(:resolved)
    expect(seen).to be(context)
  end

  it 'lets the observer bracket the block, so it can act after a normal return' do
    events = []
    described.resolution_observer = ->(_ctx, &block) do
      events << :before
      result = block.call
      events << :after
      result
    end

    described.tracking_resolution(context) { events << :proc }

    expect(events).to eq([:before, :proc, :after])
  end

  it 'lets an exception out of the block reach the observer' do
    reached = false
    described.resolution_observer = ->(_ctx, &block) do
      block.call
    rescue RuntimeError
      reached = true
      raise
    end

    expect { described.tracking_resolution(context) { raise 'blew up' } }.to raise_error(RuntimeError)
    expect(reached).to be(true)
  end
end
