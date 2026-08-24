require 'spec_helper'

describe 'Slack Respond to Button Click', :action, :slack do
  let(:action_template_id) { '019d7d4c-1758-7f73-9a76-8ffcbc1dda57' }
  let(:response_url) { 'https://hooks.slack.com/actions/T123/456/response' }

  describe 'input_schema' do
    it 'defines required response_url and text fields and optional replace_original' do
      expect(action.input_schema.field(:response_url).required).to be(true)
      expect(action.input_schema.field(:response_url).type).to eq(:string)
      expect(action.input_schema.field(:text).required).to be(true)
      expect(action.input_schema.field(:text).type).to eq(:string)
      expect(action.input_schema.field(:replace_original).visibility).to eq('optional')
      expect(action.input_schema.field(:replace_original).type).to eq(:boolean)
    end
  end

  describe 'output_schema' do
    let(:output_schema) { action.output_schema.first }

    it 'defines ok field' do
      expect(output_schema.field(:ok).type).to eq(:boolean)
    end
  end

  describe 'run' do
    let(:rate_limit_url) { response_url }
    let(:rate_limit_http_method) { :post }
    let(:rate_limit_input) { { response_url: response_url, text: 'Acknowledged' } }

    it_behaves_like 'slack rate limiting'

    context 'when responding with default replace_original' do
      before do
        stub_request(:post, response_url)
          .with(body: { text: 'Acknowledged', replace_original: true }.to_json,
                headers: { 'Content-Type' => 'application/json' })
          .to_return(status: 200, body: 'ok')
      end

      it 'posts to response_url and returns ok' do
        output = run_action({ response_url: response_url, text: 'Acknowledged' })
        expect(output[:ok]).to be(true)
      end
    end

    context 'when responding with replace_original false' do
      before do
        stub_request(:post, response_url)
          .with(body: { text: 'New message', replace_original: false }.to_json,
                headers: { 'Content-Type' => 'application/json' })
          .to_return(status: 200, body: 'ok')
      end

      it 'posts with replace_original false' do
        output = run_action({ response_url: response_url, text: 'New message', replace_original: false })
        expect(output[:ok]).to be(true)
      end
    end

    context 'when response_url returns an error' do
      before do
        stub_request(:post, response_url)
          .to_return(status: 404, body: 'expired_url')
      end

      it 'fails the job' do
        expect { run_action({ response_url: response_url, text: 'Hello' }) }
          .to raise_error(IPaaS::Job::FailJob, /Slack response_url error: 404 'expired_url'/)
      end
    end

    context 'when skipping authentication' do
      before do
        stub_request(:post, response_url)
          .to_return(status: 200, body: 'ok')
      end

      it 'does not include Authorization header' do
        run_action({ response_url: response_url, text: 'Test' })
        expect(WebMock).to have_requested(:post, response_url)
          .with { |req| req.headers['Authorization'].nil? }
      end
    end

    context 'when response_url host is not hooks.slack.com' do
      [
        ['non-Slack host', 'https://evil.example.com/x'],
        ['link-local metadata IP', 'http://169.254.169.254/latest/meta-data/'],
        ['plain http on hooks.slack.com', 'http://hooks.slack.com/actions/T123/456/response'],
        ['lookalike subdomain', 'https://hooks.slack.com.attacker.example.com/x'],
        ['userinfo trick', 'https://hooks.slack.com@attacker.example.com/x'],
        ['malformed URL', 'http://[invalid'],
      ].each do |label, url|
        it "rejects #{label} and issues no request" do
          expect { run_action({ response_url: url, text: 'Test' }) }
            .to raise_error(IPaaS::Job::FailJob, /Invalid response_url/)
          expect(WebMock).not_to have_requested(:any, /.*/)
        end
      end
    end
  end
end
