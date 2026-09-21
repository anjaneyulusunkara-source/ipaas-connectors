require 'spec_helper'

describe 'Jamf Fetch Mobile Device Inventory Action', :action do
  let(:connector_id) { '019ff02c-617b-7f56-9117-462ffc1b5cba' }
  let(:action_template_id) { '019ff02c-617b-7659-8da4-39fe93a638cd' }

  let(:all_sections) do
    %w[GENERAL HARDWARE USER_AND_LOCATION PURCHASING SECURITY NETWORK EXTENSION_ATTRIBUTES]
  end

  describe 'input_schema' do
    it 'offers the seven mobile sections, a different set from the computer action' do
      action.input_schema.field(:sections).tap do |field|
        expect(field.default).to eq(all_sections)
        expect(field.enumeration.map { |option| option[:id] }).to eq(all_sections)
      end
    end

    it 'defaults exception_handling to LENIENT so one bad device cannot stop the page' do
      action.input_schema.field(:exception_handling).tap do |field|
        expect(field.label).to eq('Exception handling')
        expect(field.type).to eq(:string)
        expect(field.default).to eq('LENIENT')
        expect(field.enumeration.map { |option| option[:id] }).to eq(%w[LENIENT STRICT])
      end
    end

    it 'defines page_size and updated_since' do
      expect(action.input_schema.field(:page_size).max).to eq(100)
      expect(action.input_schema.field(:updated_since).type).to eq(:date_time)
    end
  end

  describe 'output_schema' do
    let(:page_schema) { action.output_schema.first }
    let(:results) { page_schema.field(:results) }

    it 'only has the page schema' do
      expect(action.output_schema.map(&:reference)).to contain_exactly('page')
    end

    it 'carries device_type as a first-class field so a runbook can branch on it' do
      expect(results.field(:device_type).type).to eq(:string)
      expect(results.field(:mobile_device_id).type).to eq(:string)
    end

    # The SDK output schema has no oneOf, so results is the union of the four device-type shapes.
    # Sections absent on a variant are declared and simply arrive nil.
    it 'declares every section, including those absent on some device types' do
      [:general, :hardware, :user_and_location, :purchasing, :security, :network,
       :extension_attributes,].each do |section|
        expect(results.field(section)).not_to be_nil, "expected #{section} to be modelled"
      end
    end

    it 'includes tvOS-only general fields in the union' do
      general = results.field(:general)
      expect(general.field(:air_play_password).type).to eq(:secret_string)
      expect(general.field(:locales).type).to eq(:string)
    end

    it 'includes iPad-only general fields in the union' do
      general = results.field(:general)
      expect(general.field(:shared_ipad).type).to eq(:boolean)
      expect(general.field(:resident_users).type).to eq(:integer)
    end

    it 'names the incremental field the way Jamf returns it' do
      expect(results.field(:general).field(:last_inventory_update_date).type).to eq(:date_time)
      expect(results.field(:general).field(:last_contact_date).type).to eq(:date_time)
    end

    it 'models siteId as a bare id, since mobile records carry no site name' do
      expect(results.field(:general).field(:site_id).type).to eq(:string)
      expect(results.field(:general).field(:site)).to be_nil
    end

    it 'marks the user fields as secret strings' do
      user = results.field(:user_and_location)
      expect(user.field(:username).type).to eq(:secret_string)
      expect(user.field(:email_address).type).to eq(:secret_string)
      expect(user.field(:phone_number).type).to eq(:secret_string)
    end

    # Jamf Pro 11.31.1 returns these two, but the tenant's own /api/schema omits them, so they
    # were found by diffing a live response against the schema rather than by reading the schema.
    it 'declares the two security fields the tenant spec omits but Jamf returns' do
      security = results.field(:security)
      expect(security.field(:bootstrap_token).type).to eq(:secret_string)
      expect(security.field(:lost_mode_enabled_date).type).to eq(:date_time)
    end

    it 'has no RAM or processor fields, because mobile devices expose none' do
      hardware = results.field(:hardware)
      expect(hardware.field(:total_ram_megabytes)).to be_nil
      expect(hardware.field(:processor_count)).to be_nil
      expect(hardware.field(:capacity_mb).type).to eq(:integer)
    end
  end

  describe 'run' do
    let(:jamf_url) { 'https://acme.jamfcloud.com' }
    let(:inventory_url) { "#{jamf_url}/api/v2/mobile-devices/detail" }

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

    def input(**overrides)
      { sections: nil, page_size: nil, updated_since: nil, exception_handling: nil }.merge(overrides)
    end

    def ios_device(id)
      {
        mobileDeviceId: id,
        deviceType: 'iOS',
        general: ios_general,
        hardware: { model: 'iPhone 15 Pro', modelIdentifier: 'iPhone16,1', serialNumber: "F9#{id}" },
        userAndLocation: { username: 'user1', emailAddress: 'user1@example.test', departmentId: '-1' },
        purchasing: { warrantyExpiresDate: '2027-01-01T00:00:00.000Z' },
        security: { activationLockEnabled: true },
        network: { imei: '000000000000000' },
      }
    end

    def ios_general
      {
        displayName: 'iphone-1',
        siteId: nil,
        lastInventoryUpdateDate: '2026-08-09T18:00:00.000Z',
        deviceOwnershipType: 'Institutional',
        managed: true,
      }
    end

    # Live tenants return a fifth deviceType the spec's discriminator does not map, and its record
    # omits most sections entirely rather than nulling them. Values here are synthetic.
    def unknown_device(id)
      {
        mobileDeviceId: id,
        deviceType: 'Unknown',
        hardware: { model: '', modelIdentifier: '', serialNumber: 'SERIAL0000', deviceId: '' },
        userAndLocation: { username: 'user40', emailAddress: 'user40@example.test' },
      }
    end

    def tvos_device(id)
      {
        mobileDeviceId: id,
        deviceType: 'tvOS',
        general: { displayName: "appletv-#{id}", airPlayPassword: 'secret', locales: 'en_US' },
        hardware: { model: 'Apple TV', modelIdentifier: 'AppleTV11,1' },
        userAndLocation: { username: 'lobby' },
        purchasing: { warrantyExpiresDate: nil },
      }
    end

    def query(page: 0, page_size: 100, section: nil, filter: nil, exception_handling: 'LENIENT')
      built = {
        page: page.to_s,
        'page-size': page_size.to_s,
        sort: 'mobileDeviceId:asc',
        section: section || all_sections.join(','),
        'exception-handling': exception_handling,
      }
      built[:filter] = filter if filter
      built
    end

    def stub_page(query_params = query, status: 200, body: nil, headers: {})
      body = { totalCount: 105, results: [ios_device('1'), ios_device('2')] } if body.nil?
      stub_request(:get, inventory_url)
        .with(query: query_params)
        .to_return(status: status, body: body.is_a?(String) ? body : body.to_json, headers: headers)
    end

    describe 'the request it sends' do
      it 'asks for page zero, the seven sections, a stable sort and LENIENT handling' do
        stub = stub_page
        run_action(input)
        expect(stub).to have_been_requested
      end

      it 'lets an operator switch to STRICT to make Jamf name the problem device' do
        stub = stub_page(query(exception_handling: 'STRICT'))
        run_action(input(exception_handling: 'STRICT'))
        expect(stub).to have_been_requested
      end

      # Computers filter on a dotted path, mobile on a bare name. The connector absorbs that so a
      # runbook never has to know.
      it 'builds the incremental filter on the bare lastInventoryUpdateDate selector' do
        stub = stub_page(query(filter: 'lastInventoryUpdateDate>=2026-08-01T00:00:00.000Z'))
        run_action(input(updated_since: '2026-08-01T00:00:00Z'))
        expect(stub).to have_been_requested
      end
    end

    # The input mapping validates these before the run block executes, so the connector carries no
    # runtime guard for them. These examples pin that the platform is doing the work.
    describe 'input validation the platform performs' do
      it 'rejects a page size above the maximum' do
        expect { run_action(input(page_size: 5000)) }
          .to raise_error(IPaaS::Error, /page_size' should be at most 100/)
      end

      it 'rejects a page size below one' do
        expect { run_action(input(page_size: 0)) }
          .to raise_error(IPaaS::Error, /page_size' should be at least 1/)
      end

      it 'rejects a section this action does not model' do
        expect { run_action(input(sections: %w[GENERAL EBOOKS])) }
          .to raise_error(IPaaS::Error, /sections/)
      end

      it 'rejects an unparseable updated_since' do
        expect { run_action(input(updated_since: 'not-a-date')) }
          .to raise_error(IPaaS::Error, /updated_since' invalid, expected DateTime/)
      end

      # Unique to this action: exception_handling is the only enumeration besides sections.
      it 'rejects an exception handling mode Jamf does not offer' do
        expect { run_action(input(exception_handling: 'MAYBE')) }
          .to raise_error(IPaaS::Error, /exception_handling/)
      end
    end

    describe 'the page it returns' do
      it 'returns the envelope and the raw records with snake-cased keys' do
        stub_page
        output = run_action(input)
        expect(output[:has_next_page]).to be true
        expect(output[:total_count]).to eq(105)
        expect(output[:fetched_count]).to eq(2)
        expect(output[:results].first[:device_type]).to eq('iOS')
        expect(output[:results].first[:general][:device_ownership_type]).to eq('Institutional')
      end

      it 'reports total_count as nil when Jamf omits it rather than guessing zero' do
        stub_page(body: { results: [ios_device('1')] })
        output = run_action(input)
        expect(output[:total_count]).to be_nil
        expect(output[:fetched_count]).to eq(1)
      end

      it 'passes an Unknown device type through with its sections absent' do
        stub_page(body: { totalCount: 1, results: [unknown_device('29')] })
        record = run_action(input)[:results].first

        expect(record[:device_type]).to eq('Unknown')
        expect(record[:general]).to be_nil
        expect(record[:security]).to be_nil
        expect(record[:hardware][:serial_number]).to eq('SERIAL0000')
      end

      # An empty string is truthy in Ruby, so a runbook falling back with || would keep the "".
      it 'passes an empty model string through rather than turning it into nil' do
        stub_page(body: { totalCount: 1, results: [unknown_device('29')] })
        hardware = run_action(input)[:results].first[:hardware]
        expect(hardware[:model]).to eq('')
        expect(hardware[:model_identifier]).to eq('')
      end

      it 'passes a tvOS device through with no security or network section' do
        stub_page(body: { totalCount: 1, results: [tvos_device('88')] })
        record = run_action(input)[:results].first

        expect(record[:device_type]).to eq('tvOS')
        expect(record[:security]).to be_nil
        expect(record[:network]).to be_nil
        expect(record[:general][:air_play_password]).to be_a(IPaaS::Encryption::SecretString)
        expect(action.decrypt_secret_string(record[:general][:air_play_password])).to eq('secret')

        runbook.actions = [action]
        proc = <<~RUBY
          decrypt_secret_string(
            action_output('#{action.reference}', output_schema_reference: 'page')[:results].first[:general][:air_play_password]
          )
        RUBY
        expect(IPaaS::Connector::Common::ProcHelper.new(runbook, proc).execute).to eq('secret')
      end

      it 'passes the -1 sentinel in userAndLocation through untouched' do
        stub_page
        expect(run_action(input)[:results].first[:user_and_location][:department_id]).to eq('-1')
      end

      it 'returns an empty page when Jamf has nothing left' do
        stub_page(body: { totalCount: 105, results: [] })
        expect(run_action(input)[:has_next_page]).to be false
      end
    end

    describe 'pagination' do
      it 'stores the next page with a fingerprint' do
        stub_page
        run_action(input)

        expect(action.send(:iteration_state_value, :page)).to eq(1)
        expect(action.send(:iteration_state_value, :fingerprint)).to be_present
      end

      it 'clears the state on the empty page that ends the walk' do
        stub_page(body: { totalCount: 105, results: [] })
        expect(action(input)).to receive(:iteration_state_value=).with(nil).and_call_original
        run_action(input)
      end

      it 'resumes from the stored page and keeps counting' do
        stub_page
        run_action(input)
        state = { page: 1, fetched: 2, fingerprint: action.send(:iteration_state_value, :fingerprint) }

        second = stub_page(query(page: 1))
        action.send(:iteration_state_value=, state)
        expect(run_action(input)[:fetched_count]).to eq(4)
        expect(second).to have_been_requested
      end

      it 'fails when the inputs changed between pages' do
        stub_page(query(page: 1))
        action(input).send(:iteration_state_value=,
                           { page: 1, fetched: 2, fingerprint: 'from-a-different-request' })
        expect { run_action(input) }.to raise_error(IPaaS::Job::FailJob, /inputs changed between pages/)
      end
    end

    describe 'errors' do
      it 'fails on 401' do
        stub_page(status: 401, body: { httpStatus: 401, errors: [] })
        expect { run_action(input) }.to raise_error(IPaaS::Job::FailJob, /authentication error: 401/)
      end

      # STRICT turns one unprocessable device into a 500 for the whole page. That is deterministic,
      # so it must fail rather than reschedule forever.
      it 'fails on the 500 a STRICT page returns for a problem device' do
        stub_page(query(exception_handling: 'STRICT'), status: 500, body: 'Internal Error')
        expect { run_action(input(exception_handling: 'STRICT')) }
          .to raise_error(IPaaS::Job::FailJob, /HTTP error: 500/)
      end

      it 'reschedules on 503' do
        stub_page(status: 503, body: 'Service Unavailable')
        Timecop.freeze do
          expect { run_action(input) }.to raise_error(IPaaS::Job::RescheduleJob) { |error|
            expect(error.reschedule_after).to eq(60.seconds.from_now)
          }
        end
      end

      it 'reschedules on 429 for the interval Jamf asks for' do
        stub_page(status: 429, body: '', headers: { 'Retry-After' => '30' })
        Timecop.freeze do
          expect { run_action(input) }.to raise_error(IPaaS::Job::RescheduleJob) { |error|
            expect(error.reschedule_after).to eq(30.seconds.from_now)
          }
        end
      end
    end
  end
end
