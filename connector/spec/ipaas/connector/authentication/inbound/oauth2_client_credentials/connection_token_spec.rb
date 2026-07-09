require 'spec_helper'

describe IPaaS::Connector::Authentication::Inbound::OAuth2ClientCredentials::ConnectionToken do
  describe 'ALGORITHM' do
    it 'pins RS256 so both minter and verifier sign/verify with the same algorithm' do
      expect(described_class::ALGORITHM).to eq('RS256')
    end
  end

  describe 'MIN_RSA_KEY_BITS' do
    it 'pins the 2048-bit floor so both minter and verifier reject weak keys identically' do
      expect(described_class::MIN_RSA_KEY_BITS).to eq(2048)
    end
  end

  describe '.audience_for' do
    it 'concatenates the routing identity' do
      expect(described_class.audience_for(1, 'sol', 'conn')).to eq('1/sol/conn')
      expect(described_class.audience_for(42, 'sol-uuid', 'conn-uuid')).to eq('42/sol-uuid/conn-uuid')
    end
  end

  describe '.issuer_for' do
    it 'returns the base URL unchanged' do
      expect(described_class.issuer_for('https://ipaas.example.com')).to eq('https://ipaas.example.com')
    end
  end
end
