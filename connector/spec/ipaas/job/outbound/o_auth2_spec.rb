require 'spec_helper'

describe IPaaS::Job::Outbound::OAuth2 do
  before { IPaaS::Job::MemoryLocker.const_get(:ENTRIES).clear }

  let(:context_class) do
    Class.new do
      include IPaaS::Job::Context

      def uuid
        'oauth-spec'
      end
    end
  end
  let(:context) { context_class.new }
  let(:url)     { 'https://idp.example.com/token' }
  let(:body)    { { client_id: 'a', client_secret: 'b', grant_type: 'client_credentials' } }
  let(:fresh_response) do
    instance_double(
      Faraday::Response,
      status: 200,
      body: { access_token: 'AT-1', expires_in: 3600, token_type: 'bearer' }.to_json,
      headers: {},
    )
  end

  before { allow(context).to receive(:http_post).and_return(fresh_response) }

  def with_env(key, value)
    saved = ENV.fetch(key, :__unset)
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    saved == :__unset ? ENV.delete(key) : ENV[key] = saved
  end

  def suppress_reschedule
    yield
  rescue IPaaS::Job::RescheduleJob
    nil
  end

  describe '#oauth2_authorization_header' do
    it 'returns a cached header without calling the token endpoint' do
      context.oauth2_authorization_header(url, body)
      allow(context).to receive(:http_post).and_raise('should not be called')
      expect(context.oauth2_authorization_header(url, body)).to eq('Bearer AT-1')
    end

    it 'wraps the refresh in with_lock with a connection-scoped key and TTL' do
      lock_calls = []
      allow(context).to receive(:with_lock).and_wrap_original do |orig, key, **opts, &blk|
        lock_calls << [key, opts]
        orig.call(key, **opts, &blk)
      end
      context.oauth2_authorization_header(url, body)
      expect(lock_calls.size).to eq(1)
      key, opts = lock_calls.first
      expect(key).to start_with('oauth2:').and end_with(':refresh')
      expect(opts).to include(ttl: IPaaS::Job::Lock::DEFAULT_TTL_SECONDS)
    end

    it 'uses a lock key distinct from the cache key' do
      cache_key = context.send(:create_cache_key, url, body)
      lock_key  = context.send(:oauth2_lock_key, url, body)
      expect(lock_key).not_to eq(cache_key)
    end

    it 'derives distinct lock keys per connection (different body hashes to different keys)' do
      lock_key_a = context.send(:oauth2_lock_key, url, body)
      lock_key_b = context.send(:oauth2_lock_key, url, body.merge(client_id: 'different'))
      expect(lock_key_a).not_to eq(lock_key_b)
    end

    it 'returns the peer-written cached header on retry without calling http_post' do
      cache_key = context.send(:create_cache_key, url, body)
      context.cache_write(cache_key, 'Bearer AT-peer', 60)
      expect(context).not_to receive(:http_post)
      expect(context.oauth2_authorization_header(url, body)).to eq('Bearer AT-peer')
    end

    it 'does not write to the cache when http_post raises' do
      allow(context).to receive(:http_post).and_raise(IPaaS::Error, 'idp down')
      expect(context).not_to receive(:cache_write)
      expect { context.oauth2_authorization_header(url, body) }.to raise_error(IPaaS::Error, /idp down/)
    end

    it 'releases the lock on failure so the next caller can refresh' do
      allow(context).to receive(:http_post).and_raise(IPaaS::Error, 'idp down')
      expect { context.oauth2_authorization_header(url, body) }.to raise_error(IPaaS::Error)
      allow(context).to receive(:http_post).and_return(fresh_response)
      expect(context.oauth2_authorization_header(url, body)).to eq('Bearer AT-1')
    end

    it 'caches with expires_in minus REFRESH_OPEN_TIMEOUT' do
      Timecop.freeze do
        context.oauth2_authorization_header(url, body)
        within = (3600 - IPaaS::Job::Outbound::OAuth2::REFRESH_OPEN_TIMEOUT - 1).seconds
        beyond = (3600 - IPaaS::Job::Outbound::OAuth2::REFRESH_OPEN_TIMEOUT + 1).seconds
        Timecop.travel(within.from_now) do
          allow(context).to receive(:http_post).and_raise('should not be called')
          expect(context.oauth2_authorization_header(url, body)).to eq('Bearer AT-1')
        end
        Timecop.travel(beyond.from_now) do
          allow(context).to receive(:http_post).and_return(fresh_response)
          context.oauth2_authorization_header(url, body)
        end
      end
    end

    it 'returns the inner double-checked cached header without calling http_post when a peer wrote during the wait' do
      allow(context.locker).to receive(:try_acquire) do |*|
        context.cache_write(context.send(:create_cache_key, url, body), 'Bearer AT-peer', 60)
        SecureRandom.uuid
      end
      expect(context).not_to receive(:http_post)
      expect(context.oauth2_authorization_header(url, body)).to eq('Bearer AT-peer')
    end

    it 'releases the lock even when the inner double-check finds a peer-written cache' do
      release_spy = 0
      allow(context.locker).to receive(:release).and_wrap_original { |orig, *a|
        release_spy += 1
        orig.call(*a)
      }
      context.oauth2_authorization_header(url, body)
      expect(release_spy).to eq(1)
    end

    shared_examples 'fails closed by rescheduling without side effects' do |expected_retry_after:, expected_jitter:|
      it 'raises RescheduleJob with delay in [base, base+jitter]' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Job::RescheduleJob) do |e|
            expect(e.reschedule_after - Time.current)
              .to be_between(expected_retry_after - 0.5, expected_retry_after + expected_jitter + 0.5)
          end
      end

      it 'does not call http_post' do
        expect(context).not_to receive(:http_post)
        suppress_reschedule { context.oauth2_authorization_header(url, body) }
      end

      it 'does not write to the cache' do
        expect(context).not_to receive(:cache_write)
        suppress_reschedule { context.oauth2_authorization_header(url, body) }
      end
    end

    context 'when the lock is contended (peer holds it)' do
      before { allow(context.locker).to receive(:try_acquire).and_return(nil) }
      include_examples 'fails closed by rescheduling without side effects',
                       expected_retry_after: IPaaS::Job::Lock::RETRY_AFTER_CONTENTION.to_f,
                       expected_jitter: IPaaS::Job::Lock::RETRY_AFTER_CONTENTION_JITTER.to_f
    end

    context 'when the locker is unavailable (Redis outage simulated)' do
      before do
        allow(context.locker).to receive(:try_acquire)
          .and_raise(IPaaS::Job::LockerUnavailable, 'redis down')
      end
      include_examples 'fails closed by rescheduling without side effects',
                       expected_retry_after: IPaaS::Job::Lock::RETRY_AFTER_OUTAGE.to_f,
                       expected_jitter: IPaaS::Job::Lock::RETRY_AFTER_OUTAGE_JITTER.to_f
    end

    it 'does not clobber a peer-written cache after our lock TTL elapsed (compare-and-write)' do
      peer_value = 'Bearer AT-peer'
      allow(context).to receive(:write_if_lock_held).and_wrap_original do |_orig, *args|
        store_key = args[2]
        context.cache_write(store_key, peer_value, 60)
        false
      end
      context.oauth2_authorization_header(url, body)
      cache_key = context.send(:create_cache_key, url, body)
      expect(context.cache_read(cache_key)).to eq(peer_value)
    end
  end

  describe 'kill-switch path' do
    it 'bypasses with_lock entirely when OAUTH2_SINGLEFLIGHT_DISABLED=1' do
      with_env('OAUTH2_SINGLEFLIGHT_DISABLED', '1') do
        expect(context).not_to receive(:with_lock)
        expect(context).not_to receive(:write_if_lock_held)
        expect(context).to receive(:cache_write).with(an_instance_of(String), 'Bearer AT-1', anything)
        context.oauth2_authorization_header(url, body)
      end
    end

    it 'returns the cached header on the second call without hitting the IdP again' do
      with_env('OAUTH2_SINGLEFLIGHT_DISABLED', '1') do
        context.oauth2_authorization_header(url, body)
        allow(context).to receive(:http_post).and_raise('should not be called')
        expect(context.oauth2_authorization_header(url, body)).to eq('Bearer AT-1')
      end
    end

    it 'uses with_lock normally when the env var is unset' do
      with_env('OAUTH2_SINGLEFLIGHT_DISABLED', nil) do
        expect(context).to receive(:with_lock).and_call_original
        context.oauth2_authorization_header(url, body)
      end
    end
  end

  describe 'observability for residual TOCTOU' do
    it 'logs oauth2.lock.compare_and_write_lost when ownership was lost before write' do
      allow(context).to receive(:write_if_lock_held).and_return(false)
      expect(context).to receive(:log).with(/\Aoauth2\.lock\.compare_and_write_lost/).and_call_original
      expect(context).not_to receive(:log).with(/\Aoauth2\.lock\.lost_after_write/)
      context.oauth2_authorization_header(url, body)
    end

    it 'logs oauth2.lock.lost_after_write when ownership was lost during the cache write' do
      allow(context).to receive(:write_if_lock_held).and_return(true)
      allow(context.locker).to receive(:compare_and_call).and_return(false)
      expect(context).to receive(:log).with(/\Aoauth2\.lock\.lost_after_write/).and_call_original
      context.oauth2_authorization_header(url, body)
    end

    it 'logs neither line on the happy path' do
      allow(context).to receive(:write_if_lock_held).and_return(true)
      allow(context.locker).to receive(:compare_and_call).and_return(true)
      expect(context).not_to receive(:log).with(/oauth2\.lock\.(?:compare_and_write_lost|lost_after_write)/)
      context.oauth2_authorization_header(url, body)
    end

    it 'emits only the lock_key_sha prefix when ownership is lost — never URL, body, or secret fields' do
      allow(context).to receive(:write_if_lock_held).and_return(false)
      sensitive_body = body.merge(client_secret: 'SHOULD-NOT-LEAK', refresh_token: 'SHOULD-NOT-LEAK-RT')
      received = nil
      allow(context).to receive(:log) { |line| received = line }
      context.oauth2_authorization_header(url, sensitive_body)
      expect(received).not_to include('SHOULD-NOT-LEAK')
      expect(received).not_to include('SHOULD-NOT-LEAK-RT')
      expect(received).not_to include(url)
      expect(received).to match(/lock_key_sha=[0-9a-f]{8}/)
    end
  end

  describe 'action-time budget guard' do
    it 'keeps REFRESH_TIMEOUT < LOCK_TTL_SECONDS so the holder cannot outlive its lock' do
      expect(IPaaS::Job::Outbound::OAuth2::REFRESH_TIMEOUT)
        .to be < IPaaS::Job::Outbound::OAuth2::LOCK_TTL_SECONDS
    end

    it 'performs exactly one token exchange per lock acquisition' do
      exchanges = 0
      allow(context).to receive(:http_post) do |*_args, **_options|
        exchanges += 1
        fresh_response
      end
      context.oauth2_authorization_header(url, body)
      expect(exchanges).to eq(1)
    end
  end

  describe 'request body must not appear in error path' do
    it 'never includes client_secret or refresh_token from the request body in the error message' do
      bad_response = instance_double(Faraday::Response, status: 401, headers: {}, body: 'nope')
      allow(context).to receive(:http_post).and_return(bad_response)
      sensitive_body = body.merge(
        client_secret: 'SHOULD-NOT-LEAK-SECRET',
        refresh_token: 'SHOULD-NOT-LEAK-REFRESH-TOKEN',
      )
      expect { context.oauth2_authorization_header(url, sensitive_body) }
        .to raise_error(IPaaS::Error) do |e|
          expect(e.message).not_to include('SHOULD-NOT-LEAK-SECRET')
          expect(e.message).not_to include('SHOULD-NOT-LEAK-REFRESH-TOKEN')
        end
    end
  end

  describe 'token-endpoint HTTP status classification' do
    def stub_token_response(status:, body:, headers: {})
      response = instance_double(Faraday::Response, status: status, headers: headers, body: body)
      allow(context).to receive(:http_post).and_return(response)
    end

    shared_examples 'raises CustomerCredentialsError' do |expected_reason_match|
      it 'raises CustomerCredentialsError with the IdP host' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Job::Outbound::CustomerCredentialsError) { |e| expect(e.host).to eq('idp.example.com') }
      end

      it 'sets the reason from the OAuth2 error fields' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Job::Outbound::CustomerCredentialsError) { |e| expect(e.reason).to match(expected_reason_match) }
      end
    end

    shared_examples 'raises plain IPaaS::Error' do
      it 'raises a non-CustomerCredentialsError IPaaS::Error' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Error) { |e| expect(e).not_to be_a(IPaaS::Job::Outbound::CustomerCredentialsError) }
      end
    end

    context 'when the IdP returns 400 with invalid_grant' do
      before do
        stub_token_response(
          status: 400,
          body: { error: 'invalid_grant', error_description: 'Invalid client credentials' }.to_json,
        )
      end

      include_examples 'raises CustomerCredentialsError', /invalid_grant.*Invalid client credentials/
    end

    context 'when the IdP returns 400 with invalid_client' do
      before { stub_token_response(status: 400, body: { error: 'invalid_client' }.to_json) }
      include_examples 'raises CustomerCredentialsError', /\Ainvalid_client\z/
    end

    context 'when the IdP returns 400 with unauthorized_client' do
      before { stub_token_response(status: 400, body: { error: 'unauthorized_client' }.to_json) }
      include_examples 'raises CustomerCredentialsError', /unauthorized_client/
    end

    context 'when the IdP returns 400 with invalid_scope' do
      before do
        stub_token_response(
          status: 400,
          body: { error: 'invalid_scope', error_description: 'AADSTS70011: The provided scope is not valid' }.to_json,
        )
      end

      include_examples 'raises CustomerCredentialsError', /invalid_scope.*AADSTS70011/
    end

    context 'when the IdP returns 400 with invalid_request (generic, not a credentials error)' do
      before do
        stub_token_response(
          status: 400,
          body: { error: 'invalid_request', error_description: "AADSTS900144: missing 'scope'" }.to_json,
        )
      end

      include_examples 'raises plain IPaaS::Error'
    end

    context 'when the IdP returns 400 with unsupported_grant_type (not a credentials error)' do
      before { stub_token_response(status: 400, body: { error: 'unsupported_grant_type' }.to_json) }
      include_examples 'raises plain IPaaS::Error'
    end

    context 'when the IdP returns 400 with a non-JSON body' do
      before { stub_token_response(status: 400, body: '<html>oops</html>') }
      include_examples 'raises plain IPaaS::Error'
    end

    context 'when the IdP returns 401 with no parseable error fields' do
      before { stub_token_response(status: 401, body: 'authentication failed: token expired') }

      it 'logs minimal information as this should not happen according to spec' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Job::Outbound::CustomerCredentialsError) do |e|
            expect(e.host).to eq('idp.example.com')
            expect(e.reason).to eq('HTTP 401')
          end
      end
    end

    context 'when the IdP returns 403' do
      before { stub_token_response(status: 403, body: { error: 'forbidden' }.to_json) }
      include_examples 'raises CustomerCredentialsError', /forbidden/
    end

    context 'when the IdP returns 403 with no parseable error fields' do
      before { stub_token_response(status: 403, body: 'authentication failed: token expired') }

      it 'logs minimal information as this should not happen according to spec' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Job::Outbound::CustomerCredentialsError) do |e|
          expect(e.host).to eq('idp.example.com')
          expect(e.reason).to eq('HTTP 403')
        end
      end
    end

    context 'when the IdP returns 500' do
      before { stub_token_response(status: 500, body: 'boom') }
      include_examples 'raises plain IPaaS::Error'
    end

    context 'message sanitization' do
      let(:noisy_headers) do
        { 'set-cookie' => 'SHOULD-NOT-APPEAR=1', 'content-security-policy' => 'SHOULD-NOT-APPEAR-CSP' }
      end
      let(:noisy_body) do
        { error: 'invalid_grant', error_description: 'bad creds', extra: 'SHOULD-NOT-APPEAR-EXTRA' }.to_json
      end

      before { stub_token_response(status: 400, body: noisy_body, headers: noisy_headers) }

      it 'omits response headers from the error message' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Job::Outbound::CustomerCredentialsError) { |e| expect(e.message).not_to include('SHOULD-NOT-APPEAR') }
      end

      it 'omits unrelated response body fields from the error message' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Job::Outbound::CustomerCredentialsError) { |e| expect(e.message).not_to include('SHOULD-NOT-APPEAR-EXTRA') }
      end
    end
  end

  describe 'token-response body classification (HTTP 200)' do
    def stub_token_response(body)
      response = instance_double(Faraday::Response, status: 200, headers: {}, body: body)
      allow(context).to receive(:http_post).and_return(response)
    end

    context 'when the response is missing access_token (server protocol violation)' do
      before { stub_token_response({ token_type: 'bearer' }.to_json) }

      it 'raises a plain IPaaS::Error so the malformed response stays loud' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Error, 'Unable to authenticate, no access_token found') do |e|
            expect(e).not_to be_a(IPaaS::Job::Outbound::CustomerCredentialsError)
          end
      end
    end

    context 'when the response uses an unsupported token_type' do
      before { stub_token_response({ token_type: 'mac', access_token: 'AT' }.to_json) }

      it 'raises a plain IPaaS::Error (not a CustomerCredentialsError)' do
        expect { context.oauth2_authorization_header(url, body) }
          .to raise_error(IPaaS::Error) { |e| expect(e).not_to be_a(IPaaS::Job::Outbound::CustomerCredentialsError) }
      end
    end

    context 'when the response carries a valid bearer token (contrast)' do
      before { stub_token_response({ access_token: 'AT-OK', token_type: 'bearer', expires_in: 3600 }.to_json) }

      it 'returns the Bearer header without raising' do
        expect(context.oauth2_authorization_header(url, body)).to eq('Bearer AT-OK')
      end
    end
  end

  describe 'client credentials are unaffected by the rotation keyword' do
    let(:client_credentials_key) do
      'oauth2_authentication_header_3733caef74e7c141e7b62483045cca1abd890546bb124b8eb2252dbfe9b04344'
    end

    # Pinned literal, not a computed comparison: a computed one moves with the code and stays
    # green while every deployed cached header is silently orphaned.
    it 'derives the documented cache key, pinned as a literal' do
      expect(context.send(:create_cache_key, url, body)).to eq(client_credentials_key)
    end

    it 'derives the same cache key whether or not the rotation keyword is passed' do
      cache_keys = []
      allow(context).to receive(:cache_read).and_wrap_original do |orig, key|
        cache_keys << key
        orig.call(key)
      end
      context.oauth2_authorization_header(url, body)
      context.cache_clear(context.send(:create_cache_key, url, body))
      context.oauth2_authorization_header(url, body, rotate_refresh_token: false)
      expect(cache_keys.uniq).to eq([context.send(:create_cache_key, url, body)])
    end

    it 'stores no refresh token even when the response carries one' do
      allow(context).to receive(:http_post).and_return(
        instance_double(Faraday::Response, status: 200, headers: {},
                                           body: { access_token: 'AT-1', expires_in: 3600, token_type: 'bearer',
                                                   refresh_token: 'RT-UNEXPECTED', }.to_json),
      )
      context.oauth2_authorization_header(url, body)
      expect(context.store.read("oauth2_refresh_token_#{client_credentials_key}")).to be_nil
    end
  end

  describe 'refresh token rotation' do
    let(:rotating_context) do
      Class.new do
        include IPaaS::Job::Context

        def uuid
          'oauth-rotation-spec'
        end

        def outbound_connection
          self
        end
      end.new
    end
    let(:refresh_body) do
      { client_id: 'a', client_secret: 'b', refresh_token: 'RT-0', grant_type: 'refresh_token' }
    end
    let(:presented_refresh_tokens) { [] }

    before do
      exchange = 0
      allow(rotating_context).to receive(:http_post) do |_post_url, encoded_body, _headers, **_options|
        presented_refresh_tokens << URI.decode_www_form(encoded_body).to_h['refresh_token']
        exchange += 1
        instance_double(
          Faraday::Response,
          status: 200,
          body: { access_token: "AT-#{exchange}", expires_in: 3600, token_type: 'bearer',
                  refresh_token: "RT-#{exchange}", }.to_json,
          headers: {},
        )
      end
    end

    def exchange_twice_across_cache_expiry
      Timecop.freeze do
        rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
        beyond = (3600 - IPaaS::Job::Outbound::OAuth2::REFRESH_OPEN_TIMEOUT + 1).seconds
        Timecop.travel(beyond.from_now) do
          rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
        end
      end
    end

    it 'presents the token the provider rotated to on the second exchange' do
      exchange_twice_across_cache_expiry
      expect(presented_refresh_tokens).to eq(%w[RT-0 RT-1])
    end

    def exchange_beyond_cache_expiry(seconds_elapsed)
      Timecop.travel((3600 - IPaaS::Job::Outbound::OAuth2::REFRESH_OPEN_TIMEOUT + seconds_elapsed).seconds.from_now) do
        rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
      end
    end

    def token_response(access_token)
      body = { access_token: access_token, expires_in: 3600, token_type: 'bearer' }.to_json
      instance_double(Faraday::Response, status: 200, headers: {}, body: body)
    end

    def store_key
      "oauth2_refresh_token_#{rotating_context.send(:create_cache_key, url, refresh_body)}"
    end

    it 'reports which refresh token it presented and token rotation' do
      messages = []
      allow(rotating_context).to receive(:log) { |line| messages << line }
      Timecop.freeze do
        rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
        exchange_beyond_cache_expiry(1)
      end
      expect(messages).to eq(['Using configured refresh token', 'Storing rotated refresh token',
                              'Using rotated refresh token', 'Storing rotated refresh token',])
    end

    it 'persists the rotated token even when the access token in the same response is unusable' do
      allow(rotating_context).to receive(:http_post) do |_post_url, encoded_body, _headers, **_options|
        presented_refresh_tokens << URI.decode_www_form(encoded_body).to_h['refresh_token']
        body = { access_token: 'AT-1', expires_in: 3600, token_type: 'mac', refresh_token: 'RT-1' }.to_json
        instance_double(Faraday::Response, status: 200, headers: {}, body: body)
      end

      expect { rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true) }
        .to raise_error(IPaaS::Error, /unsupported token_type/)
      expect(rotating_context.decrypt_secret_string(rotating_context.store.read(store_key))).to eq('RT-1')
      expect(rotating_context.cache_read(rotating_context.send(:create_cache_key, url, refresh_body))).to be_nil
    end

    it 'follows the chain across three exchanges' do
      Timecop.freeze do
        rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
        exchange_beyond_cache_expiry(1)
        exchange_beyond_cache_expiry(3600)
      end
      expect(presented_refresh_tokens).to eq(%w[RT-0 RT-1 RT-2])
    end

    it 'stores the rotated token encrypted rather than in plain text' do
      rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
      stored = rotating_context.store.read(store_key)
      expect(stored).not_to eq('RT-1')
      expect(rotating_context.decrypt_secret_string(stored)).to eq('RT-1')
    end

    it 'starts a fresh store identity when the configured token is re-pasted, abandoning the old chain' do
      repasted = refresh_body.merge(refresh_token: 'RT-PASTED')
      expect(rotating_context.send(:create_cache_key, url, repasted))
        .not_to eq(rotating_context.send(:create_cache_key, url, refresh_body))
      Timecop.freeze do
        rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
        Timecop.travel(1.hour.from_now) do
          rotating_context.oauth2_authorization_header(url, repasted, rotate_refresh_token: true)
        end
      end
      expect(presented_refresh_tokens).to eq(%w[RT-0 RT-PASTED])
    end

    it 'writes no access-token cache entry when persisting the rotated token fails' do
      original_store = rotating_context.store
      allow(rotating_context).to receive(:store).and_return(original_store)
      allow(original_store).to receive(:write).and_wrap_original do |orig, key, value|
        raise 'store unavailable' if key.start_with?('oauth2_refresh_token_')
        orig.call(key, value)
      end
      expect { rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true) }
        .to raise_error('store unavailable')
      cache_key = rotating_context.send(:create_cache_key, url, refresh_body)
      expect(rotating_context.cache_read(cache_key)).to be_nil
    end

    it 'still takes the lock when the single-flight kill-switch is set' do
      acquisitions = 0
      allow(rotating_context.locker).to receive(:try_acquire).and_wrap_original do |orig, *args, **opts|
        acquisitions += 1
        orig.call(*args, **opts)
      end
      with_env('OAUTH2_SINGLEFLIGHT_DISABLED', '1') do
        rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
      end
      expect(acquisitions).to eq(1)
    end

    it 'falls back to the configured token when the stored value is blank' do
      rotating_context.store.write(store_key, '')
      rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
      expect(presented_refresh_tokens).to eq(['RT-0'])
    end

    it 'falls back to the configured token and reports it when the stored value cannot be decrypted' do
      rotating_context.store.write(store_key, 'not-decryptable')
      messages = []
      allow(rotating_context).to receive(:log) { |line| messages << line }
      expect { rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true) }
        .not_to raise_error
      expect(presented_refresh_tokens).to eq(['RT-0'])
      expect(messages).to eq(['Stored refresh token could not be read, using configured refresh token',
                              'Using configured refresh token', 'Storing rotated refresh token',])
    end

    it 'reads the rotated token from the store rather than from an instance variable' do
      shared_store = IPaaS::Job::MemoryStore.new
      allow(rotating_context.class).to receive(:store_for).and_return(shared_store)
      second_context = rotating_context.class.new
      allow(second_context).to receive(:http_post) do |_post_url, encoded_body, _headers, **_options|
        presented_refresh_tokens << URI.decode_www_form(encoded_body).to_h['refresh_token']
        token_response('AT-2')
      end
      Timecop.freeze do
        rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
        Timecop.travel(1.hour.from_now) do
          second_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
        end
      end
      expect(presented_refresh_tokens).to eq(%w[RT-0 RT-1])
    end

    it 'tolerates a non-string refresh_token rather than failing the exchange' do
      allow(rotating_context).to receive(:http_post) do |_post_url, encoded_body, _headers, **_options|
        presented_refresh_tokens << URI.decode_www_form(encoded_body).to_h['refresh_token']
        body = { access_token: 'AT-1', expires_in: 3600, token_type: 'bearer', refresh_token: 12_345 }.to_json
        instance_double(Faraday::Response, status: 200, headers: {}, body: body)
      end
      expect(rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true))
        .to eq('Bearer AT-1')
      expect(rotating_context.decrypt_secret_string(rotating_context.store.read(store_key))).to eq('12345')
    end

    context 'when the provider omits refresh_token from the response' do
      before do
        allow(rotating_context).to receive(:http_post) do |_post_url, encoded_body, _headers, **_options|
          presented_refresh_tokens << URI.decode_www_form(encoded_body).to_h['refresh_token']
          token_response('AT-1')
        end
      end

      it 'writes nothing and keeps presenting the configured token on a cold key' do
        expect { rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true) }
          .not_to raise_error
        expect(rotating_context.store.read(store_key)).to be_nil
        expect(presented_refresh_tokens).to eq(['RT-0'])
      end

      it 'leaves an already stored token intact' do
        rotating_context.store.write(store_key, rotating_context.make_secret_string('RT-STORED'))
        rotating_context.oauth2_authorization_header(url, refresh_body, rotate_refresh_token: true)
        expect(rotating_context.decrypt_secret_string(rotating_context.store.read(store_key))).to eq('RT-STORED')
        expect(presented_refresh_tokens).to eq(['RT-STORED'])
      end
    end
  end
end
