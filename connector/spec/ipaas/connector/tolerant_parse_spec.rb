require 'spec_helper'

describe 'tolerant parsing of YAML-based models' do
  let(:secret) { unpermitted_secret }

  context 'IPaaS::Connector::Connection' do
    let(:yaml) do
      {
        'uuid' => 'c0000000-0000-4000-8000-000000000001',
        'name' => 'A Connection',
        'direction' => 'outbound',
        'config_mapping' => [{ 'field_id' => 'api_key', 'fixed' => secret }],
      }.to_yaml
    end

    it 'raises without tolerant' do
      expect { IPaaS::Connector::Connection.parse(yaml) }.to raise_error(Psych::DisallowedClass)
    end

    it 'parses with tolerant and flags the mapping' do
      connection = IPaaS::Connector::Connection.parse(yaml, tolerant: true)
      mapping = connection.config_mapping.first

      expect(mapping.fixed).to be_a(IPaaS::Connector::Common::UnresolvedNode)
      expect(mapping).not_to be_valid
      expect(mapping.errors[:fixed]).to include(mapping.fixed.message)
    end
  end

  context 'IPaaS::Connector::EnvironmentVariable' do
    let(:yaml) do
      {
        'uuid' => 'e0000000-0000-4000-8000-000000000001',
        'name' => 'A Variable',
        'type' => 'secret_string',
        'description' => secret,
      }.to_yaml
    end

    it 'raises without tolerant' do
      expect { IPaaS::Connector::EnvironmentVariable.parse(yaml) }.to raise_error(Psych::DisallowedClass)
    end

    it 'parses with tolerant and flags the variable' do
      variable = IPaaS::Connector::EnvironmentVariable.parse(yaml, tolerant: true)

      expect(variable.name).to eq('A Variable')
      expect(variable.description).to be_a(IPaaS::Connector::Common::UnresolvedNode)
      expect(variable).not_to be_valid
      expect(variable.errors[:description]).to include(variable.description.message)
    end
  end

  context 'IPaaS::TestCase::TestCase' do
    let(:yaml) do
      {
        'uuid' => 't0000000-0000-4000-8000-000000000001',
        'name' => 'A Test Case',
        'actions' => [{
          'reference' => 'action-1',
          'iterations' => [{
            'input_expectations' => [
              { 'field_id' => 'api_key', 'matcher' => 'equals', 'fixed' => secret },
            ],
          }],
        }],
      }.to_yaml
    end

    it 'raises without tolerant' do
      expect { IPaaS::TestCase::TestCase.parse(yaml) }.to raise_error(Psych::DisallowedClass)
    end

    it 'parses with tolerant and flags the expectation' do
      test_case = IPaaS::TestCase::TestCase.parse(yaml, tolerant: true)
      expectation = test_case.actions.first.iterations.first.input_expectations.first

      expect(expectation.fixed).to be_a(IPaaS::Connector::Common::UnresolvedNode)
      expect(expectation).not_to be_valid
      expect(expectation.errors[:fixed]).to include(expectation.fixed.message)
    end
  end
end
