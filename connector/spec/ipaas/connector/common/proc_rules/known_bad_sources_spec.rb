require 'spec_helper'

# Every source here is a construct that must stay rejected, paired with a near-identical one that
# must stay accepted. It drives `ProcHelper#valid?` rather than a single rule, because a source can
# be rejected by one rule while the rule under test does nothing — a single-rule harness cannot see
# that. Do not move these cases into a per-rule spec.
#
# Sources off a receiverless `helpers` do not belong here: the rules accept those by design and the
# refusal happens on dispatch. They live in `spec/ipaas/connector/common/helpers_proxy_spec.rb`.
describe IPaaS::Connector::Common::ProcHelper do
  # `validated_before` short-circuits `valid?` and returns no errors, so a warm entry turns a
  # rejection expectation green. spec_helper alone populates it, hence before(:each).
  before(:each) { described_class.validated_before.clear }

  def errors_for(source)
    helper = described_class.new(nil, source)
    helper.valid?
    helper.errors
  end

  def rejected?(source)
    described_class.new(nil, source).valid? == false
  end

  ROUTES = [
    {
      route: 'reflective dispatch: reduce turns a symbol argument into the dispatched method',
      rejected: {
        '[1, 2].reduce(:eval)' => ["Method 'eval' not allowed."],
        '[1, 2].reduce(:public_send)' => ["Method 'public_send' not allowed."],
        '[1].reduce(0, "x".to_sym) { |a, b| a }' =>
          ["Method name argument to 'reduce' must be a literal symbol."],
        '["a"].reduce(*[1, :eval]) { |a, b| a }' =>
          ["Method name argument to 'reduce' must be a literal symbol."],
        '[1].reduce(0, "x".to_sym, &:+)' =>
          ["Method name argument to 'reduce' must be a literal symbol."],
        'helpers.reduce(:eval)' => ["Method 'eval' not allowed."],
        'params[:a]&.reduce(:eval)' => ["Method 'eval' not allowed."],
      },
      accepted: [
        '[1, 2].reduce(:+)',
        '[1, 2].reduce(0) { |a, b| a + b }',
        '[1, 2].reduce(0, &:+)',
        'params[:a].reduce(0, &:+)',
        'params[:h].reduce({}) { |a, (k, v)| a }',
        '[[1], [2]].reduce',
        'params[:a].dig(:eval, :system)',
      ],
    },
    {
      route: 'reflective dispatch: shapes naming a blocked constant, rejected by the constant ' \
             'block too and so not proof of the dispatch branch',
      rejected: {
        '[Kernel, "echo x"].reduce(:system)' =>
          ["Method 'system' not allowed.", "Access to 'Kernel' not allowed."],
        '["echo x"].reduce(Kernel, :system) { |a, b| a }' =>
          ["Access to 'Kernel' not allowed.", "Method 'system' not allowed."],
        '["echo x"].reduce(Kernel, &:system)' =>
          ["Method 'system' not allowed.", "Access to 'Kernel' not allowed."],
      },
      accepted: [
        '["echo x"].reduce(0) { |a, b| a }',
      ],
    },
    {
      route: 'block-pass dispatch: a symbol the validator cannot read becomes the called method',
      rejected: {
        's = :instance_eval; [self, "1+1"].reduce(&s)' => ['Block argument must be a literal symbol.'],
        '[self, "1+1"].reduce(&"instance_eval".to_sym)' => ['Block argument must be a literal symbol.'],
        's = :instance_eval; [self].each_with_object("1+1", &s)' =>
          ['Block argument must be a literal symbol.'],
        's = :instance_eval; params[:a]&.reduce(&s)' => ['Block argument must be a literal symbol.'],
        '[self, "1+1"].reduce(&[:instance_eval].first)' => ['Block argument must be a literal symbol.'],
        's = :freeze; params[:a].map(&s)' => ['Block argument must be a literal symbol.'],
      },
      accepted: [
        '[1, 2].reduce(&:+)',
        'params[:a].map(&:to_s)',
        'params[:a].select(&:present?)',
        'params[:h].transform_values(&:to_s)',
        'params[:a].each_with_object({}) { |item, acc| acc }',
      ],
    },
    {
      route: 'blocked constants: file and directory access',
      rejected: {
        'IO.read("/etc/hosts")' => ["Calling methods on 'IO' not allowed."],
        'File.read("/x")' => ["Calling methods on 'File' not allowed."],
        'File.write("/x", "y")' => ["Calling methods on 'File' not allowed."],
        'File.delete("/x")' => ["Calling methods on 'File' not allowed."],
        'File.path("/x")' => ["Calling methods on 'File' not allowed."],
        'Dir["/*"]' => ["Calling methods on 'Dir' not allowed."],
      },
      accepted: [
        'params[:io].read',
        'params[:file].path',
        'params[:dir]["/*"]',
      ],
    },
    {
      route: 'IO subclasses inherit its class methods, so blocking IO alone leaves them reachable',
      rejected: {
        'Socket.read("/etc/passwd")' => ["Calling methods on 'Socket' not allowed."],
        'Socket.write("/tmp/x", "y")' => ["Calling methods on 'Socket' not allowed."],
        '::Socket.read("/etc/passwd")' => ["Calling methods on 'Socket' not allowed."],
        'TCPSocket.read("/etc/passwd")' => ["Calling methods on 'TCPSocket' not allowed."],
        'UNIXServer.read("/etc/passwd")' => ["Calling methods on 'UNIXServer' not allowed."],
      },
      accepted: [
        'params[:socket].read',
        'params[:socket_hostname]',
      ],
    },
    {
      route: 'blocked constants: filesystem access that is not File, IO or Dir',
      rejected: {
        'FileTest.size("/etc/hosts")' => ["Calling methods on 'FileTest' not allowed."],
        'FileTest.empty?("/etc/hosts")' => ["Calling methods on 'FileTest' not allowed."],
        'FileUtils.options' => ["Calling methods on 'FileUtils' not allowed."],
      },
      accepted: [
        'params[:stat].size',
        'params[:a].empty?',
        'params[:opts].options',
      ],
    },
    {
      route: 'blocked constants: request-scoped platform state',
      rejected: {
        'RequestStore.clear!' => ["Calling methods on 'RequestStore' not allowed."],
        'RequestStore[:xray] = "y"' => ["Calling methods on 'RequestStore' not allowed."],
        'RequestStore.store["named_version_context"] = "x"' =>
          ["Calling methods on 'RequestStore' not allowed."],
      },
      accepted: [
        'params[:store][:xray] = "y"',
        'params[:store].clear',
      ],
    },
    {
      route: 'blocked constants: deserialization and reflection',
      rejected: {
        'x = YAML' => ["Access to 'YAML' not allowed."],
        'YAML.to_s' => ["Calling methods on 'YAML' not allowed."],
        'Marshal.dig(:a)' => ["Calling methods on 'Marshal' not allowed."],
        'Marshal.load("x")' =>
          ["Calling methods on 'Marshal' not allowed.", "Method 'load' not allowed."],
        'ObjectSpace.each_value' => ["Calling methods on 'ObjectSpace' not allowed."],
        'Binding.dig(:a)' => ["Calling methods on 'Binding' not allowed."],
        'Method.dig(:a)' => ["Calling methods on 'Method' not allowed."],
        'UnboundMethod.dig(:a)' => ["Calling methods on 'UnboundMethod' not allowed."],
        'RubyVM.keys' => ["Calling methods on 'RubyVM' not allowed."],
        'TracePoint.trace { |tp| tp }' => ["Calling methods on 'TracePoint' not allowed."],
      },
      accepted: [
        'x = JSON',
        'JSON.parse("{}")',
        'params[:marshal].dig(:a)',
        'params[:h].each_value',
        'params[:h].keys',
      ],
    },
    {
      route: 'blocked constants: thread and fiber local state',
      rejected: {
        'Thread.current[:executing_procs] = []' => ["Calling methods on 'Thread' not allowed."],
        'Thread.current[:ipaas_resolve_scope] = nil' => ["Calling methods on 'Thread' not allowed."],
        'Fiber[:x]' => ["Calling methods on 'Fiber' not allowed."],
        'Process.uuid' => ["Calling methods on 'Process' not allowed."],
        'Kernel.reduce(:x)' =>
          ["Calling methods on 'Kernel' not allowed.", "Method 'x' not allowed."],
      },
      accepted: [
        'Time.current',
        'params[:store][:executing_procs] = []',
        'params[:fiber][:x]',
      ],
    },
    {
      route: 'constants left out of the block as realistic namespaced leaves, rejected on the ' \
             'method name instead',
      rejected: {
        'Struct.members' => ["Method 'members' not allowed."],
        'Random.new_seed' => ["Method 'new_seed' not allowed."],
        'Data.define' => ["Method 'define' not allowed."],
        'Signal.list' => ["Method 'list' not allowed."],
        'Object.const_get(:X)' => ["Method 'const_get' not allowed."],
        'Psych.load("x")' => ["Method 'load' not allowed."],
      },
      accepted: [
        'Object.itself',
      ],
    },
    {
      route: 'the validator machinery: the constant block and the method allowlist each reject it',
      rejected: {
        'IPaaS::Connector::Common::ProcHelper.validated_before' =>
          ["Calling methods on 'ProcHelper' not allowed.", "Method 'validated_before' not allowed."],
        'IPaaS::Connector::Common::ProcHelper.validated_before.clear' =>
          ["Calling methods on 'ProcHelper' not allowed.", "Method 'validated_before' not allowed."],
        'IPaaS::Connector::Common::ProcHelper.validated_before = 1' =>
          ["Calling methods on 'ProcHelper' not allowed.", "Method 'validated_before=' not allowed."],
        'IPaaS::Connector::Common::ProcRules::ProcSafe.registry << :system' =>
          ["Access to 'ProcRules' not allowed.", "Method 'registry' not allowed."],
        'IPaaS::Connector::Common::ProcRules::ProcSafe.to_s' =>
          ["Access to 'ProcRules' not allowed."],
        'IPaaS::Connector::Common::ProcHelper.to_s' =>
          ["Calling methods on 'ProcHelper' not allowed."],
        'IPaaS::Connector::Common::ProcRules::ValidMethodsRule::RUBY_METHODS' =>
          ["Access to 'ProcRules' not allowed."],
        'IPaaS::Connector::Common::ProcRules::BASIC_RULES' =>
          ["Access to 'ProcRules' not allowed."],
      },
      accepted: [
        'params[:cache].clear',
        'params[:registry] << :system',
      ],
    },
    {
      route: 'instance and class variables on the execution context',
      rejected: {
        '@secret' => ["Access to '@secret' not allowed."],
        '@x = 1' => ["Access to '@x' not allowed."],
        '@@cv' => ["Access to '@@cv' not allowed."],
        '@@cv = 1' => ["Access to '@@cv' not allowed."],
      },
      accepted: [
        'x = 1; x',
        'local = params[:a]',
        'params[:a].each { |item| item.to_s }',
      ],
    },
    {
      route: 'rescue of a now-blocked constant reports both the constant block and the rescue rule',
      rejected: {
        'begin; params[:a].to_s; rescue Kernel; :ok; end' => [
          "Access to 'Kernel' not allowed.",
          "'rescue Kernel' is not allowed; rescue StandardError or a specific error class.",
        ],
      },
      accepted: [
        'begin; params[:a].to_s; rescue StandardError; :ok; end',
      ],
    },
    {
      route: 'namespaced leaf names, blocked in any scope unless the full path is allowlisted',
      rejected: {
        'Foo::File' => ["Access to 'File' not allowed."],
        'Zip::File' => ["Access to 'File' not allowed."],
        'Foo::Bar::Thread' => ["Access to 'Thread' not allowed."],
      },
      accepted: [
        'IPaaS::Job::Outbound::HTTP',
        '::IPaaS::Job::Outbound::HTTP',
        'IPaaS::Job::Outbound::HTTP.create_binary_part("n", "t", "d")',
        'OpenSSL::HMAC',
        'Digest::SHA256',
        'Base64.encode64("x")',
        'URI.parse("http://x")',
        'DEFAULT_PAGE_SIZE',
      ],
    },
  ].freeze

  ROUTES.each do |entry|
    describe entry[:route] do
      entry[:rejected].each do |source, messages|
        it "rejects #{source.inspect} with exactly #{messages.inspect}" do
          expect(rejected?(source)).to be(true)
          expect(errors_for(source)).to contain_exactly(*messages)
        end
      end

      entry[:accepted].each do |source|
        it "accepts #{source.inspect}" do
          expect(errors_for(source)).to be_empty
        end
      end
    end
  end

  it 'pairs every route with both a rejected and an accepted side' do
    one_sided = ROUTES.reject { |entry| entry[:rejected].any? && entry[:accepted].any? }

    expect(one_sided.map { |entry| entry[:route] }).to be_empty
  end

  it 'names an exact message for every rejected source' do
    empty = ROUTES.flat_map { |entry| entry[:rejected].select { |_, messages| messages.empty? }.keys }

    expect(empty).to be_empty
  end

  describe 'the validated_before short-circuit these examples clear' do
    let(:source) { '[1, 2].reduce(:eval)' }

    it 'reports a warm known-bad source as valid with no errors' do
      helper = described_class.new(nil, source)
      described_class.validated_before.add(helper.send(:validation_cache_key))

      expect(helper.valid?).to be(true)
      expect(helper.errors).to be_empty
    end

    it 'rejects the same source on a cold cache' do
      expect(errors_for(source)).to contain_exactly("Method 'eval' not allowed.")
    end
  end
end
