require 'spec_helper'

describe 'Jamf Fetch Sites Action', :action do
  let(:connector_id) { '019ff02c-617b-7f56-9117-462ffc1b5cba' }
  let(:action_template_id) { '01a0433b-a88a-7133-8125-16d40356c087' }

  describe 'schemas' do
    # GET /v1/sites takes no page, page-size, sort or filter parameter, so there is nothing to
    # configure and nothing to iterate.
    it 'takes no input' do
      expect(action.input_schema.fields).to be_empty
    end

    it 'has no page schema and no iteration state, because the endpoint cannot paginate' do
      expect(action.output_schema.map(&:reference)).to eq(['output'])
      expect(action.iteration_state_schema.fields).to be_empty
    end

    it 'declares sites as an array of id, division id and name' do
      sites = action.output_schema.first.field(:sites)
      expect(sites.type).to eq(:nested)
      expect(sites.array).to eq(true)
      expect(sites.field(:id).type).to eq(:string)
      expect(sites.field(:division_id).type).to eq(:string)
      expect(sites.field(:name).type).to eq(:string)
    end
  end

  describe 'run' do
    let(:jamf_url) { 'https://acme.jamfcloud.com' }
    let(:sites_url) { "#{jamf_url}/api/v1/sites" }

    let(:outbound_connection_config) do
      {
        credentials: {
          jamf_url: jamf_url,
          client_id: 'abc',
          client_secret: make_secret_string('def'),
        },
      }
    end

    before(:each) do
      body = { client_id: 'abc', client_secret: 'def', grant_type: 'client_credentials' }
      store_oauth2_header("#{jamf_url}/api/v1/oauth/token", body, token: 'jamf-token')
    end

    def stub_sites(status: 200, body: nil, headers: {})
      body = [{ id: '1', divisionId: nil, name: 'Eau Claire' }] if body.nil?
      stub_request(:get, sites_url)
        .to_return(status: status, body: body.is_a?(String) ? body : body.to_json, headers: headers)
    end

    # The response is a bare top-level array, not a { totalCount, results } envelope, which is why
    # this action parses with parse_jamf_array rather than parse_jamf_object.
    it 'maps a bare array body onto the sites field' do
      stub_sites(body: [
        { id: '1', divisionId: nil, name: 'Eau Claire' },
        { id: '2', divisionId: '550e8400-e29b-41d4-a716-446655440000', name: 'Amsterdam' },
      ])
      output = run_action

      expect(output[:sites].size).to eq(2)
      expect(output[:sites].first[:id]).to eq('1')
      expect(output[:sites].first[:name]).to eq('Eau Claire')
      expect(output[:sites].first[:division_id]).to be_nil
      expect(output[:sites].last[:division_id]).to eq('550e8400-e29b-41d4-a716-446655440000')
    end

    it 'sends no query parameters' do
      stub = stub_sites
      run_action
      expect(stub).to have_been_requested
    end

    # No sites configured is the normal answer on a fresh tenant, not an error.
    it 'returns an empty list when no sites are configured' do
      stub_sites(body: [])
      expect(run_action[:sites]).to eq([])
    end

    it 'writes no iteration state' do
      stub_sites
      expect(action).not_to receive(:iteration_state_value=)
      run_action
    end

    # Contrast with the inventory actions: an object body is correct there and wrong here.
    it 'fails when Jamf returns an object instead of an array' do
      stub_sites(body: { totalCount: 1, results: [] })
      expect { run_action }.to raise_error(IPaaS::Job::FailJob, /was not a JSON array/)
    end

    # The endpoint has no paging parameter, so whatever the tenant has comes back in one response.
    # There is no ceiling: 1000 sites is 48 KB, an eleventh of one ordinary inventory page, so a
    # cap would only ever break a large customer for no benefit.
    it 'returns a large list intact rather than truncating it' do
      stub_sites(body: (1..250).map { |index| { id: index.to_s, divisionId: nil, name: "Site #{index}" } })
      output = run_action
      expect(output[:sites].size).to eq(250)
      expect(output[:sites].last[:name]).to eq('Site 250')
    end

    it 'fails on 401' do
      stub_sites(status: 401, body: { httpStatus: 401, errors: [] })
      expect { run_action }.to raise_error(IPaaS::Job::FailJob, /authentication error: 401/)
    end

    it 'fails on 500' do
      stub_sites(status: 500, body: 'Internal Error')
      expect { run_action }.to raise_error(IPaaS::Job::FailJob, /HTTP error: 500/)
    end

    it 'reschedules on 503' do
      stub_sites(status: 503, body: 'Service Unavailable')
      Timecop.freeze do
        expect { run_action }.to raise_error(IPaaS::Job::RescheduleJob) { |error|
          expect(error.reschedule_after).to eq(60.seconds.from_now)
        }
      end
    end

    it 'reschedules on 429 for the interval Jamf asks for' do
      stub_sites(status: 429, body: '', headers: { 'Retry-After' => '30' })
      Timecop.freeze do
        expect { run_action }.to raise_error(IPaaS::Job::RescheduleJob) { |error|
          expect(error.reschedule_after).to eq(30.seconds.from_now)
        }
      end
    end

    it 'fails when the body is not JSON' do
      stub_sites(body: '<html>nope</html>')
      expect { run_action }.to raise_error(IPaaS::Job::FailJob, /was not valid JSON/)
    end
  end
end
