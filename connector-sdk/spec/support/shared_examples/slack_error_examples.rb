RSpec.shared_examples 'slack rate limiting' do
  # Including specs must define:
  #   let(:rate_limit_url)         - URL to stub
  #   let(:rate_limit_http_method) - :get or :post
  #   let(:rate_limit_input)       - input hash for run_action

  def stub_rate_limit_request
    stub = stub_request(rate_limit_http_method, rate_limit_url)
    rate_limit_http_method == :get ? stub.with(query: hash_including({})) : stub
  end

  context 'when rate limited with Retry-After' do
    before do
      stub_rate_limit_request
        .to_return(status: 429, headers: { 'Retry-After' => '30' })
    end

    it 'raises RescheduleJob with correct reschedule_after' do
      Timecop.freeze do
        expect { run_action(rate_limit_input) }
          .to raise_error(IPaaS::Job::RescheduleJob) { |error|
            expect(error.reschedule_after).to eq(30.seconds.from_now)
          }
      end
    end
  end

  context 'when rate limited without Retry-After' do
    before do
      stub_rate_limit_request
        .to_return(status: 429)
    end

    it 'raises RescheduleJob with default reschedule_after' do
      Timecop.freeze do
        expect { run_action(rate_limit_input) }
          .to raise_error(IPaaS::Job::RescheduleJob) { |error|
            expect(error.reschedule_after).to eq(60.seconds.from_now)
          }
      end
    end
  end

  context 'when server error' do
    before do
      stub_rate_limit_request
        .to_return(status: 503)
    end

    it 'raises RescheduleJob' do
      Timecop.freeze do
        expect { run_action(rate_limit_input) }
          .to raise_error(IPaaS::Job::RescheduleJob) { |error|
            expect(error.reschedule_after).to eq(60.seconds.from_now)
          }
      end
    end
  end
end
