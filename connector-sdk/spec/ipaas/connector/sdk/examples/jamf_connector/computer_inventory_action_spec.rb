require 'spec_helper'

describe 'Jamf Fetch Computer Inventory Action', :action do
  let(:connector_id) { '019ff02c-617b-7f56-9117-462ffc1b5cba' }
  let(:action_template_id) { '019ff02c-617b-7a5b-970d-e31096a5461c' }

  let(:all_sections) do
    %w[GENERAL HARDWARE OPERATING_SYSTEM STORAGE USER_AND_LOCATION PURCHASING DISK_ENCRYPTION
       EXTENSION_ATTRIBUTES]
  end

  def collect_field_ids(field)
    field.fields.flat_map { |child| [child.id.to_s] + collect_field_ids(child) }
  end

  describe 'input_schema' do
    it 'defines the sections field with every modelled section' do
      action.input_schema.field(:sections).tap do |field|
        expect(field.label).to eq('Sections')
        expect(field.type).to eq(:string)
        expect(field.array).to eq(true)
        expect(field.visibility).to eq('optional')
        expect(field.default).to eq(all_sections)
        expect(field.enumeration.map { |option| option[:id] }).to eq(all_sections)
      end
    end

    # The enumeration and the output schema have to agree in both directions. A selectable section
    # the schema does not model would be fetched and silently dropped; a modelled section missing
    # from the enumeration would be unreachable.
    it 'offers exactly the sections the output schema models' do
      modelled = action.output_schema.first.field(:results).fields.map { |field| field.id.to_s }
      offered = action.input_schema.field(:sections).enumeration.map { |option| option[:id].downcase }
      expect(modelled - %w[id udid]).to match_array(offered)
    end

    it 'defines the page_size field capped at the verified maximum' do
      action.input_schema.field(:page_size).tap do |field|
        expect(field.label).to eq('Page size')
        expect(field.type).to eq(:integer)
        expect(field.visibility).to eq('optional')
        expect(field.default).to eq(100)
        expect(field.min).to eq(1)
        expect(field.max).to eq(100)
      end
    end

    it 'defines the updated_since field' do
      action.input_schema.field(:updated_since).tap do |field|
        expect(field.label).to eq('Updated since')
        expect(field.type).to eq(:date_time)
        expect(field.required).to be_falsey
      end
    end
  end

  describe 'output_schema' do
    it 'only has the page schema' do
      expect(action.output_schema.map(&:reference)).to contain_exactly('page')
    end

    describe 'page schema' do
      let(:page_schema) { action.output_schema.first }

      it 'defines has_next_page as a required boolean' do
        page_schema.field(:has_next_page).tap do |field|
          expect(field.label).to eq('Has next page')
          expect(field.type).to eq(:boolean)
          expect(field.required).to be_truthy
        end
      end

      it 'defines the envelope counters' do
        expect(page_schema.field(:total_count).type).to eq(:integer)
        expect(page_schema.field(:fetched_count).type).to eq(:integer)
      end

      it 'defines results as an array of nested computers' do
        page_schema.field(:results).tap do |field|
          expect(field.type).to eq(:nested)
          expect(field.array).to eq(true)
        end
      end

      # These two ids are the ones a hand-rolled snake_case gets wrong, and a mismatch is silent:
      # the runbook just reads nil.
      it 'names fileVault2Status and lastReportedIpV4 the way camel_to_snake does' do
        operating_system = page_schema.field(:results).field(:operating_system)
        expect(operating_system.field(:file_vault2_status).type).to eq(:string)

        general = page_schema.field(:results).field(:general)
        expect(general.field(:last_reported_ip_v4).type).to eq(:string)
      end

      it 'treats the fields Jamf uses for identity and status as strings and timestamps' do
        general = page_schema.field(:results).field(:general)
        expect(general.field(:management_id).type).to eq(:string)
        expect(general.field(:last_contact).type).to eq(:date_time)
        expect(general.field(:report_date).type).to eq(:date_time)
      end

      it 'marks the user fields as secret strings' do
        user = page_schema.field(:results).field(:user_and_location)
        expect(user.field(:username).type).to eq(:secret_string)
        expect(user.field(:email).type).to eq(:secret_string)
      end

      it 'models general.site as an id and name pair' do
        site = page_schema.field(:results).field(:general).field(:site)
        expect(site.field(:id).type).to eq(:string)
        expect(site.field(:name).type).to eq(:string)
      end

      it 'models the extension attribute definitions Jamf nests inside general' do
        attributes = page_schema.field(:results).field(:general).field(:extension_attributes)
        expect(attributes.array).to eq(true)
        expect(attributes.field(:definition_id).type).to eq(:string)
        expect(attributes.field(:values).array).to eq(true)
      end
    end
  end

  describe 'iteration_state_schema' do
    it 'carries the page, the running total and the request fingerprint' do
      expect(action.iteration_state_schema.field(:page).type).to eq(:integer)
      expect(action.iteration_state_schema.field(:fetched).type).to eq(:integer)
      expect(action.iteration_state_schema.field(:fingerprint).type).to eq(:string)
      expect(action.iteration_state_schema.field(:fingerprint).required).to be_truthy
    end
  end

  describe 'run' do
    let(:jamf_url) { 'https://acme.jamfcloud.com' }
    let(:inventory_url) { "#{jamf_url}/api/v4/computers-inventory" }

    let(:outbound_connection_config) do
      {
        credentials: {
          jamf_url: jamf_url,
          client_id: 'abc',
          client_secret: make_secret_string('def'),
        },
      }
    end

    def fill_authorization_cache
      body = { client_id: 'abc', client_secret: 'def', grant_type: 'client_credentials' }
      store_oauth2_header("#{jamf_url}/api/v1/oauth/token", body, token: 'jamf-token')
    end

    before(:each) { fill_authorization_cache }

    # field_mapping fills every unmapped field from schema.example, so an input hash always has to
    # be explicit: run_action with no argument would send a generated updated_since.
    def input(**overrides)
      { sections: nil, page_size: nil, updated_since: nil }.merge(overrides)
    end

    # Mirrors a live record from xurrentnfr.jamfcloud.com, including the -1 sentinel, the 0
    # life expectancy and the unassigned site, so the spec exercises the shapes a runbook meets.
    def computer(id, management_id)
      {
        id: id,
        udid: "udid-#{id}",
        general: computer_general(id, management_id),
        hardware: computer_hardware,
        operatingSystem: { name: 'macOS', version: '10.14.6', fileVault2Status: 'ALL_ENCRYPTED' },
        purchasing: { purchasePrice: '2899.00', lifeExpectancy: 0 },
      }
    end

    # A record carrying every key the four sections declare, frozen here rather than derived from the
    # schema. Misnaming a declared id then leaves the real key unmodelled, which the log reports.
    def computer_extension_attribute
      { definitionId: 'ea-1', name: 'Asset tag', description: 'd', enabled: true,
        multiValue: true, values: %w[A-1 A-2], dataType: 'STRING', options: %w[o1 o2], inputType: 'TEXT', }
    end

    def computer_storage
      { bootDriveAvailableSpaceMegabytes: 120_000,
        disks: [{ id: 'disk0', device: 'disk0', model: 'APPLE SSD', revision: 'r1',
                  serialNumber: 'S-1', sizeMegabytes: 500_000, smartStatus: 'OK', type: 'SSD',
                  partitions: [{ name: 'Macintosh HD', sizeMegabytes: 500_000,
                                 availableMegabytes: 120_000, partitionType: 'BOOT',
                                 percentUsed: 76, fileVault2State: 'ENCRYPTED',
                                 fileVault2ProgressPercent: 100, lvmManaged: false, }], }], }
    end

    def computer_user_and_location
      { username: 'jdoe', realname: 'J Doe', email: 'jdoe@acme.test', position: 'Engineer',
        phone: '+31612345678', departmentId: '1', buildingId: '2', room: '3',
        extensionAttributes: [computer_extension_attribute], }
    end

    def computer_disk_encryption
      { bootPartitionEncryptionDetails: { partitionName: 'Macintosh HD',
                                          partitionFileVault2State: 'ENCRYPTED',
                                          partitionFileVault2Percent: 100, },
        individualRecoveryKeyValidityStatus: 'VALID', institutionalRecoveryKeyPresent: false,
        diskEncryptionConfigurationName: 'Standard', fileVault2Enabled: true,
        fileVault2EnabledUserNames: ['jdoe'], fileVault2EligibilityMessage: 'ok', }
    end

    # general.extension_attributes is the one of the four locations that is populated on every real
    # computer, so it is the one a misnamed id there would otherwise hide in.
    def computer_full(id, management_id)
      record = computer(id, management_id)
      record[:general] = record[:general].merge(extensionAttributes: [computer_extension_attribute])
      record.merge(storage: computer_storage,
                   userAndLocation: computer_user_and_location,
                   diskEncryption: computer_disk_encryption,
                   extensionAttributes: [computer_extension_attribute])
    end

    def computer_general(id, management_id)
      {
        name: "mac-#{id}",
        managementId: management_id,
        reportDate: '2026-04-15T07:46:57.328Z',
        lastContact: nil,
        site: { id: '-1', name: 'None' },
        lastReportedIpV4: nil,
      }
    end

    def computer_hardware
      {
        make: 'Apple',
        model: '13-inch MacBook Pro (Mid 2012)',
        serialNumber: nil,
        processorCount: 1,
        coreCount: -1,
        totalRamMegabytes: 4096,
      }
    end

    def query(page: 0, page_size: 100, section: nil, filter: nil)
      built = {
        page: page.to_s,
        'page-size': page_size.to_s,
        sort: 'id:asc',
        section: section || all_sections.join(','),
      }
      built[:filter] = filter if filter
      built
    end

    def stub_page(query_params = query, status: 200, body: nil, headers: {})
      body = { totalCount: 111, results: [computer('1', 'mgmt-1'), computer('2', 'mgmt-2')] } if body.nil?
      stub_request(:get, inventory_url)
        .with(query: query_params)
        .to_return(status: status, body: body.is_a?(String) ? body : body.to_json, headers: headers)
    end

    describe 'the request it sends' do
      # The query matcher is exact, so this also proves a full sync sends no filter parameter.
      it 'asks for page zero, every section, a stable sort and no filter' do
        stub = stub_page
        run_action(input)
        expect(stub).to have_been_requested
      end

      it 'sends only the sections the caller selected' do
        stub = stub_page(query(section: 'GENERAL,HARDWARE'))
        run_action(input(sections: %w[GENERAL HARDWARE]))
        expect(stub).to have_been_requested
      end

      it 'falls back to every section when the caller sends an empty list' do
        stub = stub_page
        run_action(input(sections: []))
        expect(stub).to have_been_requested
      end

      it 'honours an explicit page size' do
        stub = stub_page(query(page_size: 25))
        run_action(input(page_size: 25))
        expect(stub).to have_been_requested
      end

      it 'builds an incremental filter on general.reportDate' do
        stub = stub_page(query(filter: 'general.reportDate>=2026-08-01T00:00:00.000Z'))
        run_action(input(updated_since: '2026-08-01T00:00:00Z'))
        expect(stub).to have_been_requested
      end

      # Jamf rejects a numeric UTC offset: "Date [2020-01-01T00:00:00+00:00] does not match any of
      # supported formats". updated_since_utc calls .utc before .iso8601(3), so the filter always
      # carries a Z. Removing that .utc would 400 every run whose input carried an offset.
      it 'normalises an offset timestamp to Z, which is the only form Jamf accepts' do
        stub = stub_page(query(filter: 'general.reportDate>=2026-08-01T09:30:00.000Z'))
        run_action(input(updated_since: '2026-08-01T11:30:00+02:00'))
        expect(stub).to have_been_requested
      end

      it 'clamps a future updated_since to now' do
        Timecop.freeze(Time.parse('2026-09-01T12:00:00Z')) do
          stub = stub_page(query(filter: 'general.reportDate>=2026-09-01T12:00:00.000Z'))
          run_action(input(updated_since: '2099-01-01T00:00:00Z'))
          expect(stub).to have_been_requested
        end
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
        expect { run_action(input(sections: %w[GENERAL PRINTERS])) }
          .to raise_error(IPaaS::Error, /sections/)
      end

      it 'rejects an unparseable updated_since' do
        expect { run_action(input(updated_since: 'not-a-date')) }
          .to raise_error(IPaaS::Error, /updated_since' invalid, expected DateTime/)
      end
    end

    describe 'the page it returns' do
      it 'returns the envelope and the raw records with snake-cased keys' do
        stub_page
        output = run_action(input)

        expect(output[:has_next_page]).to be true
        expect(output[:total_count]).to eq(111)
        expect(output[:fetched_count]).to eq(2)
        expect(output[:results].size).to eq(2)
        expect(output[:results].first[:general][:management_id]).to eq('mgmt-1')
        expect(output[:results].first[:general][:site][:id]).to eq('-1')
        expect(output[:results].first[:operating_system][:file_vault2_status]).to eq('ALL_ENCRYPTED')
      end

      # The connector normalizes casing and nothing else, so the sentinels have to reach the
      # runbook untouched for it to decide what they mean.
      it 'passes the -1 and 0 sentinels through untouched' do
        stub_page
        record = run_action(input)[:results].first
        expect(record[:hardware][:core_count]).to eq(-1)
        expect(record[:hardware][:processor_count]).to eq(1)
        expect(record[:purchasing][:life_expectancy]).to eq(0)
        expect(record[:purchasing][:purchase_price]).to eq('2899.00')
      end

      it 'reports total_count as nil when Jamf omits it rather than guessing zero' do
        stub_page(body: { results: [computer('1', 'mgmt-1')] })
        output = run_action(input)
        expect(output[:total_count]).to be_nil
        expect(output[:fetched_count]).to eq(1)
      end

      it 'returns an empty page for a filter that matches nothing' do
        stub_page(body: { totalCount: 0, results: [] })
        output = run_action(input)
        expect(output[:has_next_page]).to be false
        expect(output[:results]).to eq([])
      end

      it 'treats a missing results key as an empty page' do
        stub_page(body: { totalCount: 0 })
        output = run_action(input)
        expect(output[:has_next_page]).to be false
        expect(output[:results]).to eq([])
      end

      it 'fails when results is not an array' do
        stub_page(body: { totalCount: 1, results: { id: '1' } })
        expect { run_action(input) }.to raise_error(IPaaS::Job::FailJob, /expected an array/)
      end
    end

    describe 'pagination' do
      def fingerprint_after_first_page
        stub_page
        run_action(input)
        action.send(:iteration_state_value, :fingerprint)
      end

      it 'stores the next page, the running total and a fingerprint' do
        stub_page
        run_action(input)

        expect(action.send(:iteration_state_value, :page)).to eq(1)
        expect(action.send(:iteration_state_value, :fetched)).to eq(2)
        expect(action.send(:iteration_state_value, :fingerprint)).to be_present
      end

      it 'clears the state on the empty page that ends the walk' do
        stub_page(body: { totalCount: 2, results: [] })
        expect(action(input)).to receive(:iteration_state_value=).with(nil).and_call_original
        run_action(input)
      end

      # Jamf answers an out-of-range page with an empty array rather than clamping to the last
      # page, which is why the walk needs no page ceiling and does not trust totalCount.
      it 'keeps going past a reached totalCount until Jamf returns nothing' do
        stub_page(body: { totalCount: 2, results: [computer('1', 'mgmt-1'), computer('2', 'mgmt-2')] })
        run_action(input)
        expect(action.send(:iteration_state_value, :page)).to eq(1)
      end

      it 'resumes from the stored page and keeps counting' do
        fingerprint = fingerprint_after_first_page
        second = stub_page(query(page: 1))
        action.send(:iteration_state_value=, { page: 1, fetched: 2, fingerprint: fingerprint })
        expect(run_action(input)[:fetched_count]).to eq(4)
        expect(second).to have_been_requested
      end

      it 'clamps a negative stored page rather than sending it to Jamf' do
        fingerprint = fingerprint_after_first_page
        action.send(:iteration_state_value=, { page: -5, fetched: -3, fingerprint: fingerprint })
        expect(run_action(input)[:fetched_count]).to eq(2)
      end

      it 'fails when the stored fingerprint belongs to another request' do
        stub_page(query(page: 1))
        action(input).send(:iteration_state_value=,
                           { page: 1, fetched: 2, fingerprint: 'from-a-different-request' })
        expect { run_action(input) }.to raise_error(IPaaS::Job::FailJob, /inputs changed between pages/)
      end

      # Without these, request_fingerprint could hash a constant and every other example here
      # would still pass. They drive the mismatch from a genuinely different input. action(input)
      # memoizes per example (spec/support/shared_contexts/action_context.rb:28), so the ivar has
      # to be cleared between the two builds.
      def state_after_first_page(first_input, first_query)
        stub_page(first_query)
        run_action(first_input)
        state = { page: action.send(:iteration_state_value, :page),
                  fetched: action.send(:iteration_state_value, :fetched),
                  fingerprint: action.send(:iteration_state_value, :fingerprint), }
        remove_instance_variable(:@action)
        state
      end

      it 'is sensitive to the sections it hashes' do
        state = state_after_first_page(input(sections: %w[GENERAL]), query(section: 'GENERAL'))
        stub_page(query(page: 1, section: 'GENERAL,HARDWARE'))

        second = input(sections: %w[GENERAL HARDWARE])
        action(second).send(:iteration_state_value=, state)
        expect { run_action(second) }.to raise_error(IPaaS::Job::FailJob, /inputs changed between pages/)
      end

      it 'is sensitive to the page size it hashes' do
        state = state_after_first_page(input(page_size: 25), query(page_size: 25))
        stub_page(query(page: 1, page_size: 50))

        second = input(page_size: 50)
        action(second).send(:iteration_state_value=, state)
        expect { run_action(second) }.to raise_error(IPaaS::Job::FailJob, /inputs changed between pages/)
      end

      it 'is stable across two pages of the same request' do
        state = state_after_first_page(input, query)
        second = stub_page(query(page: 1))

        action(input).send(:iteration_state_value=, state)
        expect(run_action(input)[:fetched_count]).to eq(4)
        expect(second).to have_been_requested
      end

      # The clamp substitutes Time.now, so hashing the clamped value would move the fingerprint
      # between two pages of one run and blame the operator for inputs that never changed.
      it 'is stable across two pages when updated_since is in the future and gets clamped' do
        future = '2099-01-01T00:00:00Z'
        clamped_to = ->(time) { "general.reportDate>=#{time.iso8601(3)}" }
        state = Timecop.freeze(Time.utc(2026, 9, 1, 12, 0, 0)) do
          state_after_first_page(input(updated_since: future),
                                 query(filter: clamped_to.call(Time.utc(2026, 9, 1, 12, 0, 0))))
        end

        Timecop.freeze(Time.utc(2026, 9, 1, 12, 0, 30)) do
          stub_page(query(page: 1, filter: clamped_to.call(Time.utc(2026, 9, 1, 12, 0, 30))))
          action(input(updated_since: future)).send(:iteration_state_value=, state)
          expect { run_action(input(updated_since: future)) }.not_to raise_error
        end
      end
    end

    describe 'unmodelled keys' do
      # expect_any_instance_of(Logger) races with the other log lines, so collect instead.
      def captured_logs
        messages = []
        allow_any_instance_of(Logger).to receive(:info).and_wrap_original do |original, *args, &block|
          messages << args.first.to_s
          original.call(*args, &block)
        end
        messages
      end

      def page_with_extra_key
        { totalCount: 2, results: [computer('1', 'mgmt-1').merge(brandNewSection: { something: 1 })] }
      end

      # The four sections the request asks for on every run but no other example carries, so a
      # misnamed declared id anywhere in them leaves the real key unmodelled and this goes red.
      it 'stays silent on a record carrying every key the requested sections declare' do
        messages = captured_logs
        stub_page(body: { totalCount: 1, results: [computer_full('1', 'mgmt-1')] })
        run_action(input)

        expect(messages.grep(/does not model/)).to be_empty
      end

      # Gutting the recursion in unmodelled_keys_in leaves the silence example above green, because a
      # consistent record is silent either way. Only a key buried inside a section proves the walk.
      it 'names a key nested inside a section, not only a top-level one' do
        messages = captured_logs
        storage = computer_storage
        storage[:disks] = storage[:disks].map { |disk| disk.merge(brandNewDiskField: 1) }
        stub_page(body: { totalCount: 1, results: [computer_full('1', 'mgmt-1').merge(storage: storage)] })
        run_action(input)

        expect(messages.grep(/does not model/).first).to include('storage.disks.brand_new_disk_field')
      end

      it 'names a key the output schema does not model' do
        messages = captured_logs
        stub_page(body: page_with_extra_key)
        run_action(input)
        expect(messages.grep(/does not model/).size).to eq(1)
        expect(messages.grep(/brand_new_section/)).not_to be_empty
      end

      # Jamf returns every top-level section whether or not it was requested, setting the
      # unrequested ones to null. This is the real production shape: warning on it meant 14 false
      # positives on the first page of every single sync.
      it 'stays silent about unrequested sections Jamf returns as null' do
        messages = captured_logs
        unrequested = %w[applications printers services certificates security ibeacons
                         localUserAccounts packageReceipts licensedSoftware softwareUpdates
                         contentCaching groupMemberships configurationProfiles attachments]
        record = computer('1', 'mgmt-1').merge(unrequested.to_h { |key| [key.to_sym, nil] })
        stub_page(body: { totalCount: 1, results: [record] })
        run_action(input)
        expect(messages.grep(/does not model/)).to be_empty
      end

      # Contrast with the example above: a null unrequested section is uninteresting, a populated
      # unknown key is the thing the warning exists for.
      it 'names a populated unknown key even alongside null unrequested sections' do
        messages = captured_logs
        record = computer('1', 'mgmt-1').merge(printers: nil, brandNewSection: { something: 1 })
        stub_page(body: { totalCount: 1, results: [record] })
        run_action(input)
        expect(messages.grep(/brand_new_section/)).not_to be_empty
        expect(messages.grep(/printers/)).to be_empty
      end

      it 'stays silent when every key is modelled' do
        messages = captured_logs
        stub_page
        run_action(input)
        expect(messages.grep(/does not model/)).to be_empty
      end

      # Checking once per run rather than once per page is deliberate: otherwise a new key would
      # log on every page of a long sync.
      it 'does not check again after the first page' do
        stub_page
        run_action(input)
        state = { page: 1, fetched: 2, fingerprint: action.send(:iteration_state_value, :fingerprint) }

        messages = captured_logs
        stub_page(query(page: 1), body: page_with_extra_key)
        action.send(:iteration_state_value=, state)
        run_action(input)
        expect(messages.grep(/does not model/)).to be_empty
      end
    end

    describe 'errors' do
      it 'fails on 401 without retrying' do
        stub_page(status: 401, body: { httpStatus: 401, errors: [] })
        expect { run_action(input) }.to raise_error(IPaaS::Job::FailJob, /authentication error: 401/)
      end

      it 'fails on 403 without retrying' do
        stub_page(status: 403, body: { httpStatus: 403, errors: [] })
        expect { run_action(input) }.to raise_error(IPaaS::Job::FailJob, /authentication error: 403/)
      end

      it 'fails on 500 rather than rescheduling' do
        stub_page(status: 500, body: 'Internal Error')
        expect { run_action(input) }.to raise_error(IPaaS::Job::FailJob, /HTTP error: 500/)
      end

      it 'reschedules on 503 with the default backoff' do
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

      it 'fails when the body is not JSON' do
        stub_page(body: '<html>nope</html>')
        expect { run_action(input) }.to raise_error(IPaaS::Job::FailJob, /was not valid JSON/)
      end

      it 'fails when the body is JSON but not an object' do
        stub_page(body: '[]')
        expect { run_action(input) }.to raise_error(IPaaS::Job::FailJob, /was not a JSON object/)
      end
    end
  end
end
