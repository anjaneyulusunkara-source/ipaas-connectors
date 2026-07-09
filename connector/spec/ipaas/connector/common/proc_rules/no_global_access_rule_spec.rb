require 'spec_helper'

describe IPaaS::Connector::Common::ProcRules::NoGlobalAccessRule do
  def errors_for(source)
    errors = []
    rule = described_class.new(nil, on_invalid: ->(message) { errors << message })
    RuboCop::AST::ProcessedSource.new(source, 3.4).ast.each_node { |node| rule.process(node) }
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
      'URI::InvalidURIError',
      'OpenSSL::HMAC',
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

  it 'reports each blocked constant once, deduplicating per name' do
    expect(errors_for('RUBY_VERSION; RUBY_VERSION; ENV["x"]'))
      .to contain_exactly("Access to 'RUBY_VERSION' not allowed.", "Calling methods on 'ENV' not allowed.")
  end

  it 'reports blocked global variables' do
    expect(errors_for('$stdout')).to contain_exactly("Access to '$stdout' not allowed.")
  end
end
