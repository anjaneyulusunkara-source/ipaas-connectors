require 'spec_helper'

describe IPaaS::Connector::Common::ProcRules::NoRescueExceptionRule do
  def errors_for(source)
    errors = []
    rule = described_class.new(nil, on_invalid: ->(message) { errors << message })
    RuboCop::AST::ProcessedSource.new(source, 3.4).ast.each_node { |node| rule.process(node) }
    errors
  end

  def not_allowed(name)
    "'rescue #{name}' is not allowed; rescue StandardError or a specific error class."
  end

  LITERAL_REQUIRED = "'rescue' requires literal error classes, e.g. 'rescue StandardError'.".freeze

  describe 'rescue classes that would capture a timeout interrupt' do
    {
      'begin; x.to_s; rescue Exception; retry; end' => 'Exception',
      'begin; x.to_s; rescue Exception; :ok; end' => 'Exception',
      'begin; x.to_s; rescue Exception => e; e.message; end' => 'Exception',
      'begin; x.to_s; rescue ::Exception; :ok; end' => 'Exception',
      'begin; x.to_s; rescue Foo::Exception; :ok; end' => 'Exception', # leaf name blocked regardless of scope
      'begin; x.to_s; rescue StandardError, Exception; :ok; end' => 'Exception',
      'begin; x.to_s; rescue Object; :ok; end' => 'Object',
      'begin; x.to_s; rescue BasicObject; :ok; end' => 'BasicObject',
      'begin; x.to_s; rescue Kernel; :ok; end' => 'Kernel',
      'begin; x.to_s; rescue SystemExit; :ok; end' => 'SystemExit',
      'begin; x.to_s; rescue ::SystemExit; :ok; end' => 'SystemExit',
      'begin; x.to_s; rescue SignalException; :ok; end' => 'SignalException',
      'begin; x.to_s; rescue Guard::DeadlineExceeded; :ok; end' => 'DeadlineExceeded',
      'begin; x.to_s; rescue ConfigTesterTimeout; :ok; end' => 'ConfigTesterTimeout',
      'begin; x.to_s; rescue MaxActionTimeExceededError; retry; end' => 'MaxActionTimeExceededError',
      'begin; x; rescue MaxTriggerProcessingTimeExceededError; :ok; end' => 'MaxTriggerProcessingTimeExceededError',
      'begin; x.to_s; rescue RequestTimeoutException; :ok; end' => 'RequestTimeoutException',
    }.each do |source, name|
      it "reports #{source.inspect} as blocking 'rescue #{name}'" do
        expect(errors_for(source)).to contain_exactly(not_allowed(name))
      end
    end
  end

  describe 'non-literal rescue classes (the validator cannot see what they catch)' do
    [
      'k = Exception; begin; x.to_s; rescue k; :ok; end',
      'begin; x.to_s; rescue *errors; :ok; end',
      'begin; x.to_s; rescue x.class; :ok; end',
    ].each do |source|
      it "reports #{source.inspect} as requiring literal error classes" do
        expect(errors_for(source)).to contain_exactly(LITERAL_REQUIRED)
      end
    end
  end

  describe 'ensure (its body runs unbounded once the deadline already fired)' do
    [
      'begin; x.to_s; ensure; x.clear; end',
      'begin; x.to_s; rescue StandardError; :ok; ensure; x.clear; end',
    ].each do |source|
      it "reports #{source.inspect} as not allowed" do
        expect(errors_for(source)).to contain_exactly("'ensure' is not allowed.")
      end
    end
  end

  describe 'permitted rescue forms' do
    # Bare rescue catches StandardError only, so a timeout interrupt still propagates;
    # retry after a StandardError rescue re-enters with the deadline timer still armed.
    [
      'begin; x.to_s; rescue; :ok; end',
      'begin; x.to_s; rescue => e; e.message; end',
      'x.to_s rescue nil',
      'begin; x.to_s; rescue StandardError; :ok; end',
      'begin; x.to_s; rescue StandardError; retry; end',
      'begin; x.to_s; rescue JSON::ParserError => e; e.message; end',
      'begin; x.to_s; rescue IPaaS::Error, URI::InvalidURIError; :ok; end',
    ].each do |source|
      it "permits #{source.inspect}" do
        expect(errors_for(source)).to be_empty
      end
    end
  end

  it 'reports each violation once, deduplicating per message' do
    source = 'begin; x.to_s; rescue Exception; begin; y.to_s; rescue Exception; :ok; end; end'
    expect(errors_for(source)).to contain_exactly(not_allowed('Exception'))
  end
end
