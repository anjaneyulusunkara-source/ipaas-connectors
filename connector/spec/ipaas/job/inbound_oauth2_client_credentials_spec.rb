require 'spec_helper'

describe IPaaS::Job::InboundOAuth2ClientCredentials do
  let(:verifier) { IPaaS::Connector::Authentication::Inbound::OAuth2ClientCredentials::Verifier }
  let(:connection_token) { IPaaS::Connector::Authentication::Inbound::OAuth2ClientCredentials::ConnectionToken }

  let(:private_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:base_url) { 'https://ipaas.example.com' }

  # Minimal host that mixes in the job-context extension (and Context, for
  # fail_job!) and supplies the routing identity the extension reads (mirrors
  # context_spec's TestContext).
  let(:job_class) do
    Class.new do
      include IPaaS::Job::Context
      include IPaaS::Job::InboundOAuth2ClientCredentials

      attr_accessor :account_id, :solution, :uuid
    end
  end

  let(:solution) { Struct.new(:uuid).new('sol-uuid') }
  let(:job) do
    job_class.new.tap do |j|
      j.account_id = 42
      j.solution = solution
      j.uuid = 'conn-uuid'
    end
  end

  before { verifier.reset! }
  after { verifier.reset! }

  describe '#oauth2_client_credentials_setup_info' do
    it 'surfaces the token URL built from the configured base URL' do
      verifier.configure_url_only { |c| c.base_url = 'https://ipaas.example.com' }
      section = job.oauth2_client_credentials_setup_info['OAuth 2.0 client credentials']
      expect(section['Token URL']).to eq(value: 'https://ipaas.example.com/oauth/token/42/sol-uuid/conn-uuid',
                                         copyable: true)
      expect(section['Grant type']).to eq(value: 'client_credentials')
    end

    it 'strips a trailing slash from the base URL' do
      verifier.configure_url_only { |c| c.base_url = 'https://ipaas.example.com/' }
      url = job.oauth2_client_credentials_setup_info['OAuth 2.0 client credentials']['Token URL'][:value]
      expect(url).to eq('https://ipaas.example.com/oauth/token/42/sol-uuid/conn-uuid')
    end

    it 'returns an empty hash when the base URL is not configured' do
      expect(job.oauth2_client_credentials_setup_info).to eq({})
    end
  end

  describe '#verify_inbound_oauth2_client_credentials_jwt!' do
    before do
      verifier.configure do |c|
        c.public_key_pem = private_key.public_key.to_pem
        c.base_url = base_url
      end
    end

    # Signs with the private-key counterpart of the verifier's public key,
    # through the shared ConnectionToken claim builders, so it round-trips.
    def mint_token(subject: 'the-client-id', **extra_claims)
      payload = IPaaS::Job::JWT.make_jwt_payload(
        issuer_claim: connection_token.issuer_for(base_url), subject_claim: subject,
        audience_claim: connection_token.audience_for(42, 'sol-uuid', 'conn-uuid'),
        expiration_time_claim: 600, **extra_claims
      )
      IPaaS::Job::JWT.encode_jwt(
        payload, algorithm: connection_token::ALGORITHM, pem: private_key.to_pem,
                 header_fields: { typ: 'JWT', alg: connection_token::ALGORITHM }
      )
    end

    def request_with(authorization)
      headers = authorization.nil? ? {} : { 'Authorization' => authorization }
      double('request', headers: headers)
    end

    it 'decodes a valid bearer token against the configured public key' do
      result = job.verify_inbound_oauth2_client_credentials_jwt!(request_with("Bearer #{mint_token}"))
      expect(result[:payload]['aud']).to eq('42/sol-uuid/conn-uuid')
      expect(result[:payload]['iss']).to eq(base_url)
      expect(result[:payload]['sub']).to eq('the-client-id')
    end

    it 'logs the audit claims of a verified token to the job log' do
      expect(job).to receive(:log)
        .with('Verified inbound OAuth 2.0 bearer token (sub: the-client-id, sol_ver: abc1234)')
      job.verify_inbound_oauth2_client_credentials_jwt!(request_with("Bearer #{mint_token(sol_ver: 'abc1234')}"))
    end

    it 'logs the ctx claim ahead of sub and sol_ver for a debug-minted token' do
      expect(job).to receive(:log)
        .with('Verified inbound OAuth 2.0 bearer token (ctx: debug, sub: debug:42, sol_ver: abc1234)')
      token = mint_token(subject: 'debug:42', ctx: 'debug', sol_ver: 'abc1234')
      job.verify_inbound_oauth2_client_credentials_jwt!(request_with("Bearer #{token}"))
    end

    it 'logs without the audit claims when a token does not carry them' do
      token = mint_token
      payload, = JWT.decode(token, nil, false)
      expect(payload).not_to have_key('sol_ver')
      expect(job).to receive(:log).with('Verified inbound OAuth 2.0 bearer token (sub: the-client-id)')
      job.verify_inbound_oauth2_client_credentials_jwt!(request_with("Bearer #{token}"))
    end

    it 'accepts a lowercase/uppercase auth scheme (RFC 7235 schemes are case-insensitive)' do
      %w[bearer BEARER bEaReR].each do |scheme|
        result = job.verify_inbound_oauth2_client_credentials_jwt!(request_with("#{scheme} #{mint_token}"))
        expect(result[:payload]['sub']).to eq('the-client-id')
      end
    end

    it 'fails the job when the Authorization header is absent' do
      expect { job.verify_inbound_oauth2_client_credentials_jwt!(request_with(nil)) }
        .to raise_error(IPaaS::Job::FailJob, 'Missing or malformed Authorization header.')
    end

    it 'fails the job when the Authorization header is not a Bearer scheme' do
      expect { job.verify_inbound_oauth2_client_credentials_jwt!(request_with('Basic abc123')) }
        .to raise_error(IPaaS::Job::FailJob, 'Missing or malformed Authorization header.')
    end

    it 'fails the job when the bearer value is blank after the scheme' do
      expect { job.verify_inbound_oauth2_client_credentials_jwt!(request_with('Bearer    ')) }
        .to raise_error(IPaaS::Job::FailJob, 'Missing or malformed Authorization header.')
    end

    it 'fails the job with the wrapped message when the bearer token cannot be verified' do
      expect { job.verify_inbound_oauth2_client_credentials_jwt!(request_with('Bearer not.a.jwt')) }
        .to raise_error(IPaaS::Job::FailJob, /\AInvalid bearer token: /)
    end
  end
end
