# The connection's durable store, as ArtifactCache reaches it through +store.store+:
# untimed read/write with no expiry, mirroring SolutionStore and IPaaS::Job::MemoryStore
# in JSON round-tripping values so stored symbol keys surface as strings.
class FakeDurableStore
  def initialize
    @entries = {}
  end

  def read(key)
    raw = @entries[key]
    raw.nil? ? nil : JSON.parse(raw)
  end

  def write(key, value)
    @entries[key] = JSON.generate(value)
    nil
  end

  def delete(key)
    @entries.delete(key)
  end
end
