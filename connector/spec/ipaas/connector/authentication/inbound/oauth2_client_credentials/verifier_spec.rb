require 'spec_helper'

describe IPaaS::Connector::Authentication::Inbound::OAuth2ClientCredentials::Verifier do
  let(:verifier) { described_class }
  let(:connection_token) { IPaaS::Connector::Authentication::Inbound::OAuth2ClientCredentials::ConnectionToken }

  let(:private_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:base_url) { 'https://ipaas.example.com' }

  let(:account_id) { 42 }
  let(:solution_uuid) { 'sol-uuid' }
  let(:connection_uuid) { 'conn-uuid' }
  let(:audience) { connection_token.audience_for(account_id, solution_uuid, connection_uuid) }

  before do
    verifier.reset!
    verifier.configure do |c|
      c.public_key_pem = private_key.public_key.to_pem
      c.base_url = base_url
    end
  end

  after { verifier.reset! }

  # Signs a token with the *private* key counterpart of the verifier's public
  # key, through the same ConnectionToken claim builders the token issuer uses,
  # so mint -> verify round-trips.
  def mint_test_token(account_id:, solution_uuid:, connection_uuid:, ttl_seconds: 600)
    payload = IPaaS::Job::JWT.make_jwt_payload(
      issuer_claim: connection_token.issuer_for(base_url), subject_claim: connection_uuid,
      audience_claim: connection_token.audience_for(account_id, solution_uuid, connection_uuid),
      expiration_time_claim: ttl_seconds
    )
    IPaaS::Job::JWT.encode_jwt(
      payload, algorithm: connection_token::ALGORITHM, pem: private_key.to_pem,
               header_fields: { typ: 'JWT', alg: connection_token::ALGORITHM }
    )
  end

  describe '.verify!' do
    it 'verifies a token whose decoded aud equals the full routing identity' do
      token = mint_test_token(account_id: account_id, solution_uuid: solution_uuid,
                              connection_uuid: connection_uuid)
      decoded = verifier.verify!(token, account_id, solution_uuid, connection_uuid)
      expect(decoded[:payload]['aud']).to eq(audience)
      expect(decoded[:payload]['iss']).to eq(base_url)
      expect(decoded[:payload]['sub']).to eq(connection_uuid)
      expect(decoded[:payload]['exp']).to be > Time.now.to_i
    end

    it 'rejects a token whose audience is for a different tenant' do
      # Connection UUID matches, but account_id segment differs
      cross_tenant = mint_test_token(account_id: 1, solution_uuid: solution_uuid,
                                     connection_uuid: connection_uuid)
      expect do
        verifier.verify!(cross_tenant, 2, solution_uuid, connection_uuid)
      end.to raise_error(IPaaS::Error)
    end

    it 'rejects a token signed by a different key (alg=HS256 confusion blocked by RS256 pin)' do
      # Use the public key as an HMAC secret — alg=HS256 confusion attack
      public_pem = private_key.public_key.to_pem
      evil_payload = { iss: base_url, aud: audience, exp: Time.now.to_i + 600 }
      evil_token = JWT.encode(evil_payload, public_pem, 'HS256')
      expect { verifier.verify!(evil_token, account_id, solution_uuid, connection_uuid) }.to raise_error(IPaaS::Error)
    end

    it 'rejects an unsigned (alg=none) token' do
      none_token = JWT.encode({ iss: base_url, aud: audience, exp: Time.now.to_i + 600 }, nil, 'none')
      expect { verifier.verify!(none_token, account_id, solution_uuid, connection_uuid) }.to raise_error(IPaaS::Error)
    end

    it 'rejects an expired token' do
      token = mint_test_token(account_id: account_id, solution_uuid: solution_uuid,
                              connection_uuid: connection_uuid, ttl_seconds: 60)
      Timecop.freeze(Time.now + 3600) do
        expect { verifier.verify!(token, account_id, solution_uuid, connection_uuid) }
          .to raise_error(IPaaS::Error)
      end
    end

    it 'rejects a token with a different issuer' do
      other_key = OpenSSL::PKey::RSA.new(2048)
      payload = { iss: 'https://attacker.example.com', aud: audience, exp: Time.now.to_i + 600 }
      token = JWT.encode(payload, other_key, 'RS256')
      expect { verifier.verify!(token, account_id, solution_uuid, connection_uuid) }.to raise_error(IPaaS::Error)
    end

    it 'passes a non-blank pem to decode_jwt!' do
      expect(IPaaS::Job::JWT).to receive(:decode_jwt!) do |_token, **opts|
        expect(opts[:pem]).to be_present
        expect(opts[:algorithm]).to eq('RS256')
        expect(opts[:validate_iat]).to eq(:never)
        expect(opts[:validate_jti]).to eq(:never)
        { header: {}, payload: { 'aud' => audience } }
      end
      verifier.verify!('any.token.here', account_id, solution_uuid, connection_uuid)
    end
  end

  describe '.configure validation' do
    it 'rejects a missing public key' do
      verifier.reset!
      expect do
        verifier.configure { |c| c.base_url = base_url }
      end.to raise_error(IPaaS::Error, /public key PEM is required/)
    end

    it 'rejects a missing base url' do
      verifier.reset!
      expect do
        verifier.configure { |c| c.public_key_pem = private_key.public_key.to_pem }
      end.to raise_error(IPaaS::Error, /base URL is required/)
    end

    it 'rejects an invalid PEM' do
      verifier.reset!
      expect do
        verifier.configure do |c|
          c.public_key_pem = 'not a pem'
          c.base_url = base_url
        end
      end.to raise_error(IPaaS::Error, /invalid public key PEM/)
    end

    it 'rejects a private PEM passed as the public key' do
      verifier.reset!
      expect do
        verifier.configure do |c|
          c.public_key_pem = private_key.to_pem
          c.base_url = base_url
        end
      end.to raise_error(IPaaS::Error, /private key, not a public key/)
    end

    it 'rejects an RSA key weaker than the 2048-bit floor' do
      verifier.reset!
      expect do
        verifier.configure do |c|
          c.public_key_pem = OpenSSL::PKey::RSA.new(1024).public_key.to_pem
          c.base_url = base_url
        end
      end.to raise_error(IPaaS::Error, /at least 2048 bits/)
    end
  end
end
