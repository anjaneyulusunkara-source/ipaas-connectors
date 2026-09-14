require 'spec_helper'

describe IPaaS::Connector::Common::ProcRules::NoGlobalAccessRule do
  def errors_for(source)
    errors = []
    rule = described_class.new(nil, on_invalid: ->(message) { errors << message })
    target = IPaaS::Connector::Common::ProcHelper::TARGET_RUBY_VERSION
    RuboCop::AST::ProcessedSource.new(source, target).ast.each_node { |node| rule.process(node) }
    errors
  end

  describe 'blocked global access' do
    {
      'ENV["PATH"]' => "Calling methods on 'ENV' not allowed.",
      '::ENV["PATH"]' => "Calling methods on 'ENV' not allowed.",
      '::ENVx["x"]' => "Calling methods on 'ENVx' not allowed.",
      'RUBY_VERSION' => "Access to 'RUBY_VERSION' not allowed.",
      '::RUBY_VERSION' => "Access to 'RUBY_VERSION' not allowed.",
      'ENVx' => "Access to 'ENVx' not allowed.",
      '::ENVx' => "Access to 'ENVx' not allowed.",
      'x = ::ENV' => "Access to 'ENV' not allowed.",
      '::ENV&.[]("PATH")' => "Access to 'ENV' not allowed.",
      "\"\#{::ENV}\"" => "Access to 'ENV' not allowed.", # literal source text: "#{::ENV}"
      'Object::ENV["PATH"]' => "Calling methods on 'ENV' not allowed.",
      'URI::ENV["PATH"]' => "Calling methods on 'ENV' not allowed.",
      '::Object::ENV' => "Access to 'ENV' not allowed.",
      'Object::Object::ENV' => "Access to 'ENV' not allowed.",
      '(Object)::ENV' => "Access to 'ENV' not allowed.",
      'Object.itself::ENV' => "Access to 'ENV' not allowed.",
      '[Object][0]::ENV' => "Access to 'ENV' not allowed.",
      'Foo::ENV' => "Access to 'ENV' not allowed.",
      '::Foo::ENV' => "Access to 'ENV' not allowed.",
      'Foo::Bar::RUBY_VERSION' => "Access to 'RUBY_VERSION' not allowed.",
      'defined?(ENV)' => "Access to 'ENV' not allowed.",
      'case 1; in Foo::ENV then 2; end' => "Access to 'ENV' not allowed.",
    }.each do |source, message|
      it "reports #{source.inspect} as #{message.inspect}" do
        expect(errors_for(source)).to contain_exactly(message)
      end
    end
  end

  describe 'permitted constant access' do
    # A constant is allowed when its leaf name is not a blocked global, regardless of scope.
    [
      'Foo::BAR',
      'JSON::ParserError',
      '::JSON::ParserError',
      'JSON.parse("{}")',
      'URI::InvalidURIError',
      'URI.parse("http://x")',
      'JWT.decode("x")',
      'OpenSSL::HMAC',
      'Digest::SHA256',
      'Base64.encode64("x")',
      'Time.now',
      'Hash',
      'Array',
      'String',
      'DateTime',
      'DEFAULT_PAGE_SIZE',
    ].each do |source|
      it "permits #{source.inspect}" do
        expect(errors_for(source)).to be_empty
      end
    end
  end

  describe 'allowlisted trusted paths (leaf name collides with a blocked global)' do
    # `HTTP` is a top-level constant in the platform (http gem), so it lands in NOT_ALLOWED_NAMES
    # there; stub that here so the connector env matches. `IPaaS::Job::Outbound::HTTP` is our own
    # class (used by the `upload_image` helper) and is explicitly allowlisted; the same leaf reached
    # through any other path stays blocked.
    before { stub_const("#{described_class}::NOT_ALLOWED_NAMES", Set[:HTTP]) }

    [
      'IPaaS::Job::Outbound::HTTP',
      '::IPaaS::Job::Outbound::HTTP',
      'IPaaS::Job::Outbound::HTTP.create_binary_part(name, type, data)',
    ].each do |source|
      it "permits #{source.inspect}" do
        expect(errors_for(source)).to be_empty
      end
    end

    {
      'HTTP["x"]' => "Calling methods on 'HTTP' not allowed.",
      'Foo::HTTP' => "Access to 'HTTP' not allowed.",
      'Job::Outbound::HTTP' => "Access to 'HTTP' not allowed.",
    }.each do |source, message|
      it "still blocks #{source.inspect}" do
        expect(errors_for(source)).to contain_exactly(message)
      end
    end
  end

  describe 'allowlisted whole paths (namespace root is blocked)' do
    # The root is blocked, so a constant inside it is reachable only when its whole path is
    # allowlisted: `SecurityUtils` carries the constant-time comparison a signature check needs.
    # Siblings under the same root stay blocked, and so does a longer path through the entry.
    [
      'ActiveSupport::SecurityUtils.secure_compare(expected, received)',
      '::ActiveSupport::SecurityUtils.secure_compare(expected, received)',
      'ActiveSupport::SecurityUtils&.secure_compare(expected, received)',
    ].each do |source|
      it "permits #{source.inspect}" do
        expect(errors_for(source)).to be_empty
      end
    end

    # Permitted only where it receives the call. Every other position is refused, including a bare
    # read, because a path bound to a local can be reopened there and no check on this node would
    # see it.
    [
      'ActiveSupport::SecurityUtils',
      '::ActiveSupport::SecurityUtils',
      'x = ActiveSupport::SecurityUtils',
      'x = ActiveSupport::SecurityUtils; class << x; undef secure_compare; end',
      '[ActiveSupport::SecurityUtils]',
    ].each do |source|
      it "refuses #{source.inspect} outside the call position" do
        expect(errors_for(source)).to contain_exactly("Access to 'ActiveSupport' not allowed.")
      end
    end

    {
      'ActiveSupport' => "Access to 'ActiveSupport' not allowed.",
      'ActiveSupport.eager_load!' => "Calling methods on 'ActiveSupport' not allowed.",
      'ActiveSupport::IsolatedExecutionState[:x] = 1' => "Access to 'ActiveSupport' not allowed.",
      'ActiveSupport::ExecutionContext.clear' => "Access to 'ActiveSupport' not allowed.",
      'ActiveSupport::SecurityUtils::Foo' => "Access to 'ActiveSupport' not allowed.",
      'Foo::ActiveSupport::SecurityUtils' => "Access to 'ActiveSupport' not allowed.",
    }.each do |source, message|
      it "still blocks #{source.inspect}" do
        expect(errors_for(source)).to contain_exactly(message)
      end
    end

    # Permitting a path permits reading it. Reopening a module is not governed by these rules at
    # all, so a permitted path must not be usable as the target of one.
    [
      'class << ActiveSupport::SecurityUtils; undef secure_compare; end',
      'class << ActiveSupport::SecurityUtils.itself; undef secure_compare; end',
      'class << (ActiveSupport::SecurityUtils); undef secure_compare; end',
      'module ActiveSupport::SecurityUtils; undef secure_compare; end',
      'module ActiveSupport::SecurityUtils; alias secure_compare inspect; end',
      'class ActiveSupport::SecurityUtils; undef secure_compare; end',
      'module ActiveSupport::SecurityUtils; module Foo; end; end',
      'module ActiveSupport::SecurityUtils; end',
      'class << (nil || ActiveSupport::SecurityUtils); undef secure_compare; end',
      'class << (false || ActiveSupport::SecurityUtils); undef secure_compare; end',
      'class << (true ? ActiveSupport::SecurityUtils : nil); undef secure_compare; end',
      'class << (ActiveSupport::SecurityUtils && ActiveSupport::SecurityUtils); undef x; end',
    ].each do |source|
      it "refuses #{source.inspect} as a definition target" do
        expect(errors_for(source)).to contain_exactly("Access to 'ActiveSupport' not allowed.")
      end
    end

    # A longer path is a different path, and wrapping the permitted one in an expression that
    # carries its value must not launder it into that longer lookup.
    [
      '(ActiveSupport::SecurityUtils)::Foo',
      '((ActiveSupport::SecurityUtils))::Foo',
      'begin; ActiveSupport::SecurityUtils; end::Foo',
      'ActiveSupport::SecurityUtils.itself::Foo',
      'ActiveSupport::SecurityUtils.itself::ExecutionContext.clear',
      '[ActiveSupport::SecurityUtils][0]::Foo',
      'defined?((ActiveSupport::SecurityUtils)::Foo)',
    ].each do |source|
      it "refuses #{source.inspect} as a longer path" do
        expect(errors_for(source)).to contain_exactly("Access to 'ActiveSupport' not allowed.")
      end
    end

    # The other allowlist covers longer paths beneath its entries, so without the same refusal a
    # permitted namespace could be reopened. Refused whichever allowlist would exempt it. `Job` is
    # the reported name in both environments; the `HTTP` leaf is only blocked where the platform's
    # gems are loaded, so that case belongs in the platform spec.
    [
      'class << IPaaS::Job; undef name; end',
      'module IPaaS::Job; undef name; end',
      'class << IPaaS::Job::Outbound::HTTP; undef create_binary_part; end',
    ].each do |source|
      it "refuses #{source.inspect} as a definition target" do
        expect(errors_for(source)).to contain_exactly("Access to 'Job' not allowed.")
      end
    end

    it 'carries only entries whose root is blocked, so no entry is redundant' do
      roots = described_class::ALLOWED_WHOLE_CONST_PATHS.map(&:first)

      expect(roots).to all(satisfy { |root| described_class::NOT_ALLOWED_NAMES.include?(root) })
    end

    it 'freezes every entry so a proc cannot widen the allowlist it is checked against' do
      expect(described_class::ALLOWED_WHOLE_CONST_PATHS).to be_frozen
      expect(described_class::ALLOWED_WHOLE_CONST_PATHS).to all(be_frozen)
    end
  end

  it 'reports each blocked constant once, deduplicating per name' do
    expect(errors_for('RUBY_VERSION; RUBY_VERSION; ENV["x"]'))
      .to contain_exactly("Access to 'RUBY_VERSION' not allowed.", "Calling methods on 'ENV' not allowed.")
  end

  it 'reports blocked global variables' do
    expect(errors_for('$stdout')).to contain_exactly("Access to '$stdout' not allowed.")
  end

  describe 'blocked class names' do
    calling_methods_on = {
      File: ['File.read("/x")', 'File.write("/x", "y")', 'File.delete("/x")', 'File.path("/x")'],
      FileTest: ['FileTest.size("/x")', 'FileTest.empty?("/x")'],
      FileUtils: ['FileUtils.options'],
      RequestStore: ['RequestStore.clear!', 'RequestStore[:xray] = "y"'],
      ProcHelper: ['ProcHelper.validated_before'],
      ProcRules: ['ProcRules.constants'],
      SourceParser: ['IPaaS::Connector::Common::SourceParser.read("1+1").parse'],
      Ripper: ['Ripper.slice("1+1", "ident")'],
      Prism: ['Prism.parse("1+1")'],
      Socket: ['Socket.read("/x")', 'Socket.write("/x", "y")'],
      BasicSocket: ['BasicSocket.read("/x")'],
      IPSocket: ['IPSocket.read("/x")'],
      TCPSocket: ['TCPSocket.read("/x")'],
      TCPServer: ['TCPServer.read("/x")'],
      UDPSocket: ['UDPSocket.read("/x")'],
      UNIXSocket: ['UNIXSocket.read("/x")'],
      UNIXServer: ['UNIXServer.read("/x")'],
      Dir: ['Dir["/*"]'],
      ViteRuby: ['ViteRuby.run(["--version"])'],
      Gem: ['Gem.path'],
      Bundler: ['Bundler.environment'],
      Thor: ['Thor.options'],
      Kernel: ['Kernel.system("echo x")'],
      ObjectSpace: ['ObjectSpace.count_objects'],
      Marshal: ['Marshal.load("x")'],
      Binding: ['Binding.of_caller'],
      Method: ['Method.instance_method(:x)'],
      UnboundMethod: ['UnboundMethod.instance_method(:x)'],
      Process: ['Process.spawn("echo x")'],
      Thread: ['Thread.current[:executing_procs] = []'],
      Fiber: ['Fiber[:x]'],
      Ractor: ['Ractor.new { 1 }'],
      RubyVM: ['RubyVM.stat'],
      TracePoint: ['TracePoint.trace { |tp| tp }'],
    }.freeze

    calling_methods_on.each do |name, sources|
      sources.each do |source|
        it "reports #{source.inspect} as calling methods on '#{name}'" do
          expect(errors_for(source)).to contain_exactly("Calling methods on '#{name}' not allowed.")
        end
      end

      it "reports a bare read of #{name} as access" do
        expect(errors_for(name.to_s)).to contain_exactly("Access to '#{name}' not allowed.")
      end
    end

    # Names without a bespoke case above get a generated one, so the pin below still proves every
    # blocked name is exercised without restating the list.
    (described_class::NOT_ALLOWED_CLASS_NAMES - calling_methods_on.keys).each do |name|
      it "reports a bare read of #{name} as access" do
        expect(errors_for(name.to_s)).to contain_exactly("Access to '#{name}' not allowed.")
      end

      it "reports a method call on #{name} as calling methods" do
        expect(errors_for("#{name}.first")).to contain_exactly("Calling methods on '#{name}' not allowed.")
      end
    end

    it 'exercises every name in NOT_ALLOWED_CLASS_NAMES' do
      generated = described_class::NOT_ALLOWED_CLASS_NAMES - calling_methods_on.keys
      expect(calling_methods_on.keys + generated).to match_array(described_class::NOT_ALLOWED_CLASS_NAMES)
    end

    it 'folds NOT_ALLOWED_CLASS_NAMES into NOT_ALLOWED_NAMES' do
      expect(described_class::NOT_ALLOWED_NAMES).to include(*described_class::NOT_ALLOWED_CLASS_NAMES)
    end
  end

  # A nested constant carries its namespace's methods, and Enumerable arrives by extend rather than
  # on the leaf itself, so the reachable form names the nested constant while the namespace is what
  # gets reported. Blocking the namespace root is what closes these.
  describe 'reach through a nested constant under a blocked namespace' do
    {
      'Etc::Passwd.to_a' => 'Etc',
      'Etc::Group.each { |group| group }' => 'Etc',
      'Nokogiri::EncodingHandler.delete("UTF-8")' => 'Nokogiri',
      'Gem::Specification.each { |spec| spec }' => 'Gem',
    }.each do |source, name|
      it "reports #{source.inspect} as access to '#{name}'" do
        expect(errors_for(source)).to contain_exactly("Access to '#{name}' not allowed.")
      end
    end
  end

  describe 'IO, YAML and CSV' do
    {
      'IO.read("/etc/hosts")' => "Calling methods on 'IO' not allowed.",
      'x = IO' => "Access to 'IO' not allowed.",
      'YAML.load("x")' => "Calling methods on 'YAML' not allowed.",
      'x = YAML' => "Access to 'YAML' not allowed.",
      'CSV.read("/etc/passwd")' => "Calling methods on 'CSV' not allowed.",
      'x = CSV' => "Access to 'CSV' not allowed.",
    }.each do |source, message|
      it "reports #{source.inspect} as #{message.inspect}" do
        expect(errors_for(source)).to contain_exactly(message)
      end
    end

    it 'blocks IO, YAML and CSV while the remaining exemptions stay allowed' do
      expect(described_class::NOT_ALLOWED_NAMES).to include(:IO, :YAML, :CSV)
      expect(described_class::NOT_ALLOWED_NAMES).not_to include(:JWT, :URI, :JSON)
    end
  end

  describe 'instance and class variables' do
    {
      '@secret' => "Access to '@secret' not allowed.",
      '@x = 1' => "Access to '@x' not allowed.",
      '@@cv' => "Access to '@@cv' not allowed.",
      '@@cv = 1' => "Access to '@@cv' not allowed.",
    }.each do |source, message|
      it "reports #{source.inspect} as #{message.inspect}" do
        expect(errors_for(source)).to contain_exactly(message)
      end
    end

    it 'reports each variable name once' do
      expect(errors_for('@x; @x; @x = 2; @@y; @@y; @@y = 2'))
        .to contain_exactly("Access to '@x' not allowed.", "Access to '@@y' not allowed.")
    end

    it 'reports an instance variable and a global variable in the same source' do
      expect(errors_for('@x; $stdout'))
        .to contain_exactly("Access to '@x' not allowed.", "Access to '$stdout' not allowed.")
    end

    [
      'x = 1; x',
      'local = params[:a]',
      'params[:a].each { |item| item.to_s }',
    ].each do |source|
      it "permits the local variables in #{source.inspect}" do
        expect(errors_for(source)).to be_empty
      end
    end
  end
end
