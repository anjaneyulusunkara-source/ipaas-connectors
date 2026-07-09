require 'spec_helper'

describe IPaaS::Connector::Dsl::FunctionMixin do
  before(:each) do
    skip_function_capture_validation
  end

  it 'allows function' do
    function_tester = Class.new(DslTester) do
      function :foo
    end.new
    function_tester.foo do
      'Hello World!'
    end
    expect(function_tester.foo.call).to eq('Hello World!')
  end

  it 'does not allow functions to capture local variables' do
    enable_function_capture_validation

    function_tester = Class.new(DslTester) do
      function :foo
    end.new
    a = 1

    expect do
      function_tester.foo do
        'Hello World!'
      end
    end.to raise_error(ArgumentError, "Function 'foo' captures local variables: [:function_tester, :a].")

    expect(a).to eq(1)
  end

  it 'only logs a warning for captured local variables outside the test environment' do
    enable_function_capture_validation
    allow(IPaaS).to receive(:env).and_return('production')
    logger = instance_double(Logger)
    stub_const('Rails', double(logger: logger)) # plain double since Rails is not loaded in this suite
    allow(logger).to receive(:warn)

    function_tester = Class.new(DslTester) do
      function :foo
    end.new
    a = 1

    expect do
      function_tester.foo do
        'Hello World!'
      end
    end.not_to raise_error

    # contrast with the raising spec above: captured variables are reported in a warning instead
    expect(logger).to have_received(:warn)
      .with("Function 'foo' captures local variables: [:logger, :function_tester, :a].")
    expect(function_tester.foo.call).to eq('Hello World!')
    expect(a).to eq(1)
  end

  context 'validation' do
    # In this context we supply a standalone lambda to the function so that `ProcHelper#proc_source`
    # does not validate the `test` receiver as a bare method call.

    it 'validates presence if required' do
      test = Class.new(DslTester) do
        function :parse, required: true
      end.new
      expect(test).not_to be_valid
      expect(test.errors[:parse].first).to eq("function is required, define 'parse do ... end'.")

      fn = -> { 'bar' }
      test.parse(&fn)
      expect(test).to be_valid
      expect(test.parse.call).to eq('bar')
    end

    it 'validates the function itself' do
      test = Class.new(DslTester) do
        function :parse
      end.new
      fn = -> { instance_eval('"Hello World!"', __FILE__, __LINE__) }
      test.parse(&fn)
      test.parse.call # for 100% coverage
      expect(test).not_to be_valid
      expect(test.errors[:parse].first).to eq("invalid: Method 'instance_eval' not allowed.")
    end

    describe 'call_function' do
      it 'calls the function' do
        test = Class.new(DslTester) do
          function :parse
        end.new
        called = nil
        fn = -> { called = name }
        test.parse(&fn)
        test.call_function(:parse, double(name: :bar))
        expect(called).to eq(:bar)
      end

      it 'accepts parameters' do
        test = Class.new(DslTester) do
          function :parse
        end.new
        called = nil
        fn = ->(param) { called = param }
        test.parse(&fn)
        test.call_function(:parse, Object.new, :bar)
        expect(called).to eq(:bar)
      end

      it 'does not fail when the function is not present' do
        test = Class.new(DslTester) do
          function :parse
        end.new
        test.call_function(:parse, Object.new, :bar)
      end

      it 'raises an error when the function is invalid' do
        test = Class.new(DslTester) do
          function :parse
          function :foo
        end.new
        fn = -> { send(:present?) }
        test.parse(&fn)
        expect do
          test.call_function(:parse, nil)
        end.to raise_error(IPaaS::Error, "Function 'parse' invalid: invalid: Method 'send' not allowed.")
        test.parse.call # 100% test coverage
      end
    end
  end
end
