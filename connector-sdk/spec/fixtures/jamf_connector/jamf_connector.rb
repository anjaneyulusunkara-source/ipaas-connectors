class JamfConnector < IPaaS::Connector::Definition
  API_BASE_PATH            = '/api'.freeze
  TOKEN_API_ROUTE          = '/v1/oauth/token'.freeze
  VERSION_API_ROUTE        = '/v1/jamf-pro-version'.freeze
  COMPUTERS_API_ROUTE      = '/v4/computers-inventory'.freeze
  MOBILE_DEVICES_API_ROUTE = '/v2/mobile-devices/detail'.freeze
  SITES_API_ROUTE          = '/v1/sites'.freeze

  DEFAULT_PAGE_SIZE = 100
  MAX_PAGE_SIZE     = 100

  COMPUTERS_SORT      = 'id:asc'.freeze
  MOBILE_DEVICES_SORT = 'mobileDeviceId:asc'.freeze

  COMPUTERS_UPDATED_FIELD      = 'general.reportDate'.freeze
  MOBILE_DEVICES_UPDATED_FIELD = 'lastInventoryUpdateDate'.freeze

  COMPUTER_SECTIONS = %w[
    GENERAL HARDWARE OPERATING_SYSTEM STORAGE USER_AND_LOCATION PURCHASING DISK_ENCRYPTION
    EXTENSION_ATTRIBUTES
  ].freeze

  MOBILE_DEVICE_SECTIONS = %w[
    GENERAL HARDWARE USER_AND_LOCATION PURCHASING SECURITY NETWORK EXTENSION_ATTRIBUTES
  ].freeze

  EXCEPTION_HANDLING_MODES   = %w[LENIENT STRICT].freeze
  DEFAULT_EXCEPTION_HANDLING = 'LENIENT'.freeze

  connector '019ff02c-617b-7f56-9117-462ffc1b5cba' do
    name 'Jamf Connector'
    avatar '/assets/icons/jamf.svg'
    description <<~END_OF_DESCRIPTION
      ## Overview
      Reads Apple device inventory from [Jamf Pro](https://www.jamf.com/) into Xurrent using the [Jamf Pro API](https://developer.jamf.com/jamf-pro/reference/jamf-pro-api). Macs and mobile devices are separate resources in Jamf with different schemas, so this connector exposes them as two independent actions plus a small lookup for site names.

      ## Prerequisites
      - A Jamf Pro tenant, either Jamf Cloud (`https://your-tenant.jamfcloud.com`) or an on-premises Jamf Pro host.
      - An API Role and an API Client. In Jamf Pro go to **Settings > System > API Roles and Clients**. Create the **API role** first, then create the **API client** and assign that role to it.
      - The API role needs these privileges: `Read Computers`, `Read Mobile Devices` and `Read Sites`.
      - From the API client, take the **Client ID** shown on the client, and use the separate **Generate client secret** button for the secret. The secret is displayed once and cannot be retrieved later.

      ## Authentication
      Fill in three fields when you create the connection.

      | Field | Where to get it |
      |---|---|
      | Jamf Pro URL | Your Jamf Pro address, for example `https://acme.jamfcloud.com`. Leave off `/api`. |
      | Client ID | Shown on the API client in **Settings > System > API Roles and Clients**. |
      | Client secret | Produced by **Generate client secret** on that API client. |

      The connection test calls Jamf and reports the Jamf Pro version it reached, so a wrong URL or a bad secret is visible before any runbook runs.

      ## Triggers
      None. This connector is outbound only.

      ## Actions

      ### Fetch Computer Inventory
      Returns Mac inventory records from `GET /api/v4/computers-inventory`, one page per invocation. Re-invoke while `has_next_page` is true.

      **Use case**: the extract step of a CMDB synchronization for Macs. Pair it with **Fetch Mobile Device Inventory** to cover the whole Apple fleet.

      **Permissions required**: `Read Computers`

      #### Input Parameters

      | Parameter | Type | Required | Default | Description |
      |-----------|------|----------|---------|-------------|
      | sections | String[] | No | all eight | Which inventory sections to request. Every selectable section is modelled in the output. |
      | page_size | Integer | No | 100 | Records per page, 1 to 100. |
      | updated_since | Date time | No | - | Only return computers whose `general.reportDate` is at or after this moment. Omit for a full sync. |

      #### Output

      | Field Name | Type | Description |
      |---|---|---|
      | `has_next_page` | Boolean | `true` while more pages remain. Re-invoke the action until `false`. |
      | `total_count` | Integer | What Jamf reported for this request. `nil` means Jamf omitted it, which is not the same as zero computers. |
      | `fetched_count` | Integer | Records returned so far across this run. Compare with `total_count` after the last page to detect a fleet that changed mid-run. |
      | `results` | Object[] | One object per computer, keys snake-cased, values exactly as Jamf returned them. |

      #### Operational notes
      - Jamf returns `-1` in numeric hardware fields to mean "unknown", not zero. On a sample tenant `hardware.coreCount` was `-1` on 110 of 111 computers. Guard `nrOfCores`, `nrOfProcessors` and `ramAmount` in the runbook before writing them.
      - `purchasing.lifeExpectancy` uses `0` for unknown rather than `-1`, and `purchasing.purchasePrice` is a decimal string such as `"2899.00"`, not a number.
      - `general.site` is `{"id": "-1", "name": "None"}` when no site is assigned. Treat `id == "-1"` as unassigned rather than resolving it.
      - `general.lastContact` can be null on every computer in a tenant while `general.reportDate` is populated. Fall back to `reportDate` for both status and last-seen.
      - `hardware.serialNumber` is frequently empty. Use `general.managementId` as the stable identifier.

      ### Fetch Mobile Device Inventory
      Returns iPhone, iPad, Apple TV, Apple Watch and Vision Pro inventory from `GET /api/v2/mobile-devices/detail`, one page per invocation.

      **Use case**: the extract step of a CMDB synchronization for mobile devices.

      **Permissions required**: `Read Mobile Devices`

      #### Input Parameters

      | Parameter | Type | Required | Default | Description |
      |-----------|------|----------|---------|-------------|
      | sections | String[] | No | all seven | Which inventory sections to request. Every selectable section is modelled in the output. |
      | page_size | Integer | No | 100 | Records per page, 1 to 100. |
      | updated_since | Date time | No | - | Only return devices whose `lastInventoryUpdateDate` is at or after this moment. Omit for a full sync. |
      | exception_handling | String | No | LENIENT | `LENIENT` returns a page even when Jamf cannot process a device, with that device's problem sections set to null. `STRICT` makes Jamf return 500 for the whole page instead, naming one problem device at a time. |

      #### Output

      Same envelope as **Fetch Computer Inventory**. `results` carries the union of all device-type shapes.

      #### Operational notes
      - `device_type` tells you which shape a record has. Jamf documents `iOS`, `tvOS`, `watchOS` and `visionOS`, and also returns `Unknown` for devices it cannot classify. Branch on it.
      - Sections that do not apply to a device type are either null or absent from the record. Apple TVs carry no `security` or `network`, Apple Watches carry no `purchasing`. Read every section defensively.
      - `hardware.model` and `hardware.modelIdentifier` can be empty strings rather than null. An empty string is truthy in Ruby, so use `.presence` when falling back to a default.
      - `general.siteId` is an id with no name attached. Use **Fetch Sites** to resolve it. `userAndLocation.departmentId` and `buildingId` use `"-1"` for unassigned.
      - `deviceOwnershipType` has no `Personal` value. The BYOD enrollment types are `UserEnrollment` and `AccountDrivenUserEnrollment`, and the field cannot be filtered server-side, so exclude BYOD devices in the runbook.
      - Mobile devices expose no RAM and no processor fields at all.

      ### Fetch Sites
      Returns every Jamf site from `GET /api/v1/sites` in a single call.

      **Use case**: build an id to name lookup so mobile device records, which carry `general.siteId` and no site name, can be given a location.

      **Permissions required**: `Read Sites`

      #### Input Parameters
      None.

      #### Output

      | Field Name | Type | Description |
      |---|---|---|
      | `sites` | Object[] | One object per site: `id`, `division_id`, `name`. `division_id` may be null. |

      #### Operational notes
      - This endpoint takes no paging parameters, so it always returns every site in one response, however many the tenant has. The count is logged.
      - An empty list is a normal answer and means no sites are configured. Treat it as "no location available", not as an error.

      ## Rate Limiting and Error Handling
      Jamf does not publish rate limit numbers, and Jamf Cloud throttles at the load balancer. On `429` or `503` the connector waits for the interval in the `Retry-After` header, or 60 seconds when the header is absent, then retries. On `401` or `403` the job fails immediately, because a credential or privilege problem does not improve on retry. `500`, `502` and `504` also fail immediately, since a Jamf-side error is not fixed by asking again.

      ## Best Practices
      - Always pass `sections` explicitly, or accept the default. Jamf returns only the `GENERAL` section when the parameter is missing, which is the most common way a Jamf integration silently loses data.
      - Keep `updated_since` and `sections` identical for every page of one run. Changing them mid-run changes the underlying result set, and the connector fails the job rather than page into a different list.
      - Pair incremental runs with a periodic full run. Jamf's filtering excludes records whose filter field is null, so a device that has never reported never matches an incremental query.
      - Leave `exception_handling` on `LENIENT` for scheduled syncs. Switch to `STRICT` only when you are diagnosing a specific device, because it stops the whole page.
      - Call **Fetch Sites** once per run and cache the result. Site names change rarely.

      ## Common Use Cases
      - Nightly full synchronization of Macs and mobile devices into the Xurrent CMDB as discovered configuration items.
      - Hourly incremental synchronization using `updated_since` to pick up only devices that reported since the previous run.
      - Reporting on OS versions, disk encryption state, or warranty expiry across an Apple fleet.
      - Finding devices that have stopped checking in, by comparing `general.reportDate` against the current time.

      ## References
      - [Jamf Pro API overview](https://developer.jamf.com/jamf-pro/docs/jamf-pro-api-overview) explains authentication, paging, sorting and filtering across the whole API.
      - [Obtain an access token using an API Client](https://developer.jamf.com/jamf-pro/reference/postoauthtoken) documents the client credentials exchange this connector uses.
      - [API Roles and Clients](https://learn.jamf.com/bundle/jamfpro-documentation-current/page/API_Roles_and_Clients.html) walks through creating the role and client in the Jamf Pro interface.
      - [Filtering with RSQL](https://developer.jamf.com/jamf-pro/docs/filtering-with-rsql) covers the filter grammar behind `updated_since`, including which fields each endpoint allows.
      - [Return paginated Computer Inventory records](https://developer.jamf.com/jamf-pro/reference/get_v4-computers-inventory) and [Return paginated Mobile Device Inventory records](https://developer.jamf.com/jamf-pro/reference/get_v2-mobile-devices-detail) are the reference pages for the two inventory actions.
      - Your own tenant serves its exact API contract at `https://your-tenant.jamfcloud.com/api/schema`, which is the most reliable description of what your Jamf version returns.
    END_OF_DESCRIPTION

    outbound_connection do
      config_schema do
        field :credentials, 'Credentials', :nested, required: true do
          field :jamf_url, 'Jamf Pro URL', :uri,
                required: true,
                hint: 'Your Jamf Pro address, for example https://acme.jamfcloud.com. ' \
                      'Leave off /api. On-premises Jamf Pro hosts are supported.'
          field :client_id, 'Client ID', :string,
                required: true,
                hint: 'Settings > System > API Roles and Clients in Jamf Pro. ' \
                      'Create the API role first, then the client. The Client ID is shown on the client.'
          field :client_secret, 'Client secret', :secret_string,
                required: true,
                hint: 'Use Generate client secret on the API client. Jamf shows the value once.'
        end
      end

      config_tester do
        response = http_get(helpers.jamf_url(VERSION_API_ROUTE), nil, nil, open_timeout: 2, timeout: 5)
        if response.status == 200
          version = helpers.parse_jamf_object(response)[:version]
          { status: :success, message: "Connection successful. Jamf Pro version #{version}." }
        elsif [401, 403].include?(response.status)
          { status: :failed, message: "Jamf rejected the credentials (HTTP #{response.status})." }
        else
          { status: :error, message: "Jamf version check failed (HTTP #{response.status}): '#{response.body}'" }
        end
      end

      authenticate do |request|
        credentials = config[:credentials]
        body = oauth2_client_credentials_body(credentials[:client_id],
                                              decrypt_secret_string(credentials[:client_secret]))
        request.headers['Authorization'] = oauth2_authorization_header(helpers.jamf_url(TOKEN_API_ROUTE), body)
        request.headers['Accept'] = 'application/json'
      end
    end

    action '019ff02c-617b-7a5b-970d-e31096a5461c' do
      name 'Fetch Computer Inventory'
      avatar '/assets/icons/jamf.svg'
      nested true

      description <<~END_OF_DESCRIPTION
        Returns one page of Mac inventory records from the Jamf Pro API, with keys snake-cased and values exactly as Jamf returned them. Re-invoke while `has_next_page` is true.

        Numeric hardware fields use `-1` for "unknown" and `purchasing.lifeExpectancy` uses `0`, so guard them before writing to the CMDB. `general.lastContact` is often null even when `general.reportDate` is populated.
      END_OF_DESCRIPTION

      input_schema do
        field :sections, 'Sections', :string,
              array: true,
              visibility: 'optional',
              default: COMPUTER_SECTIONS,
              hint: 'Inventory sections to request. Jamf returns only the general section when this is empty.',
              enumeration: COMPUTER_SECTIONS.map { |section| { id: section, label: section.titleize } }
        field :page_size, 'Page size', :integer,
              visibility: 'optional', default: DEFAULT_PAGE_SIZE, min: 1, max: MAX_PAGE_SIZE,
              hint: 'Computers per page.'
        field :updated_since, 'Updated since', :date_time,
              hint: 'Only return computers whose general.reportDate is at or after this moment. ' \
                    'Leave empty for a full sync.'
      end

      output_schema 'page' do
        field :has_next_page, 'Has next page', :boolean, required: true
        field :total_count, 'Total count', :integer,
              hint: 'What Jamf reported for this request. Empty means Jamf omitted it, not zero computers.'
        field :fetched_count, 'Fetched count', :integer,
              hint: 'Records returned so far across this run.'
        field :results, 'Results', :nested, array: true do
          field :id, 'ID', :string
          field :udid, 'UDID', :string
          field :general, 'General', :nested do
            field :name, 'Name', :string
            field :last_ip_address, 'Last IP address', :string
            field :last_reported_ip_v4, 'Last reported IP v4', :string
            field :last_reported_ip_v6, 'Last reported IP v6', :string
            field :jamf_binary_version, 'Jamf binary version', :string
            field :platform, 'Platform', :string
            field :barcode1, 'Barcode1', :string
            field :barcode2, 'Barcode2', :string
            field :asset_tag, 'Asset tag', :string
            field :remote_management, 'Remote management', :nested do
              field :managed, 'Managed', :boolean
              field :management_username, 'Management username', :secret_string
            end
            field :supervised, 'Supervised', :boolean
            field :mdm_capable, 'MDM capable', :nested do
              field :capable, 'Capable', :boolean
              field :capable_users, 'Capable users', :string, array: true
              field :user_management_info, 'User management info', :nested, array: true do
                field :capable_user, 'Capable user', :secret_string
                field :management_id, 'Management ID', :string
              end
            end
            field :report_date, 'Report date', :date_time
            field :last_check_in, 'Last check in', :date_time
            field :last_contact, 'Last contact', :date_time
            field :last_cloud_backup_date, 'Last cloud backup date', :date_time
            field :last_enrolled_date, 'Last enrolled date', :date_time
            field :mdm_profile_expiration, 'MDM profile expiration', :date_time
            field :initial_entry_date, 'Initial entry date', :date
            field :distribution_point, 'Distribution point', :string
            field :enrollment_method, 'Enrollment method', :nested do
              field :id, 'ID', :string
              field :object_name, 'Object name', :string
              field :object_type, 'Object type', :string
            end
            field :site, 'Site', :nested do
              field :id, 'ID', :string
              field :name, 'Name', :string
            end
            field :itunes_store_account_active, 'iTunes Store account active', :boolean
            field :enrolled_via_automated_device_enrollment, 'Enrolled via automated device enrollment', :boolean
            field :user_approved_mdm, 'User approved MDM', :boolean
            field :declarative_device_management_enabled, 'Declarative device management enabled', :boolean
            field :extension_attributes, 'Extension attributes', :nested, array: true do
              field :definition_id, 'Definition ID', :string
              field :name, 'Name', :string
              field :description, 'Description', :string
              field :enabled, 'Enabled', :boolean
              field :multi_value, 'Multi value', :boolean
              field :values, 'Values', :string, array: true
              field :data_type, 'Data type', :string
              field :options, 'Options', :string, array: true
              field :input_type, 'Input type', :string
            end
            field :management_id, 'Management ID', :string
            field :last_logged_in_username_self_service, 'Last logged in username self service', :secret_string
            field :last_logged_in_username_self_service_timestamp,
                  'Last logged in username self service timestamp', :date_time
            field :last_logged_in_username_binary, 'Last logged in username binary', :secret_string
            field :last_logged_in_username_binary_timestamp, 'Last logged in username binary timestamp', :date_time
            field :last_logged_in_username_mdm, 'Last logged in username MDM', :secret_string
            field :last_logged_in_username_mdm_timestamp, 'Last logged in username MDM timestamp', :date_time
          end
          field :hardware, 'Hardware', :nested do
            field :make, 'Make', :string
            field :model, 'Model', :string
            field :model_identifier, 'Model identifier', :string
            field :serial_number, 'Serial number', :string
            field :processor_speed_mhz, 'Processor speed MHz', :integer
            field :processor_count, 'Processor count', :integer
            field :core_count, 'Core count', :integer
            field :processor_type, 'Processor type', :string
            field :processor_architecture, 'Processor architecture', :string
            field :bus_speed_mhz, 'Bus speed MHz', :integer
            field :cache_size_kilobytes, 'Cache size kilobytes', :integer
            field :network_adapter_type, 'Network adapter type', :string
            field :mac_address, 'MAC address', :string
            field :alt_network_adapter_type, 'Alt network adapter type', :string
            field :alt_mac_address, 'Alt MAC address', :string
            field :total_ram_megabytes, 'Total RAM megabytes', :integer
            field :open_ram_slots, 'Open RAM slots', :integer
            field :battery_capacity_percent, 'Battery capacity percent', :integer
            field :battery_health, 'Battery health', :string
            field :smc_version, 'SMC version', :string
            field :nic_speed, 'NIC speed', :string
            field :optical_drive, 'Optical drive', :string
            field :boot_rom, 'Boot ROM', :string
            field :ble_capable, 'BLE capable', :boolean
            field :supports_ios_app_installs, 'Supports iOS app installs', :boolean
            field :apple_silicon, 'Apple silicon', :boolean
            field :provisioning_udid, 'Provisioning UDID', :string
            field :extension_attributes, 'Extension attributes', :nested, array: true do
              field :definition_id, 'Definition ID', :string
              field :name, 'Name', :string
              field :description, 'Description', :string
              field :enabled, 'Enabled', :boolean
              field :multi_value, 'Multi value', :boolean
              field :values, 'Values', :string, array: true
              field :data_type, 'Data type', :string
              field :options, 'Options', :string, array: true
              field :input_type, 'Input type', :string
            end
          end
          field :operating_system, 'Operating system', :nested do
            field :name, 'Name', :string
            field :version, 'Version', :string
            field :build, 'Build', :string
            field :supplemental_build_version, 'Supplemental build version', :string
            field :rapid_security_response, 'Rapid security response', :string
            field :active_directory_status, 'Active directory status', :string
            field :file_vault2_status, 'FileVault 2 status', :string
            field :software_update_device_id, 'Software update device ID', :string
            field :extension_attributes, 'Extension attributes', :nested, array: true do
              field :definition_id, 'Definition ID', :string
              field :name, 'Name', :string
              field :description, 'Description', :string
              field :enabled, 'Enabled', :boolean
              field :multi_value, 'Multi value', :boolean
              field :values, 'Values', :string, array: true
              field :data_type, 'Data type', :string
              field :options, 'Options', :string, array: true
              field :input_type, 'Input type', :string
            end
          end
          field :storage, 'Storage', :nested do
            field :boot_drive_available_space_megabytes, 'Boot drive available space megabytes', :integer
            field :disks, 'Disks', :nested, array: true do
              field :id, 'ID', :string
              field :device, 'Device', :string
              field :model, 'Model', :string
              field :revision, 'Revision', :string
              field :serial_number, 'Serial number', :string
              field :size_megabytes, 'Size megabytes', :integer
              field :smart_status, 'Smart status', :string
              field :type, 'Type', :string
              field :partitions, 'Partitions', :nested, array: true do
                field :name, 'Name', :string
                field :size_megabytes, 'Size megabytes', :integer
                field :available_megabytes, 'Available megabytes', :integer
                field :partition_type, 'Partition type', :string
                field :percent_used, 'Percent used', :integer
                field :file_vault2_state, 'File vault2 state', :string
                field :file_vault2_progress_percent, 'File vault2 progress percent', :integer
                field :lvm_managed, 'Lvm managed', :boolean
              end
            end
          end
          field :user_and_location, 'User and location', :nested do
            field :username, 'Username', :secret_string
            field :realname, 'Realname', :secret_string
            field :email, 'Email', :secret_string
            field :position, 'Position', :string
            field :phone, 'Phone', :secret_string
            field :department_id, 'Department ID', :string
            field :building_id, 'Building ID', :string
            field :room, 'Room', :string
            field :extension_attributes, 'Extension attributes', :nested, array: true do
              field :definition_id, 'Definition ID', :string
              field :name, 'Name', :string
              field :description, 'Description', :string
              field :enabled, 'Enabled', :boolean
              field :multi_value, 'Multi value', :boolean
              field :values, 'Values', :string, array: true
              field :data_type, 'Data type', :string
              field :options, 'Options', :string, array: true
              field :input_type, 'Input type', :string
            end
          end
          field :purchasing, 'Purchasing', :nested do
            field :leased, 'Leased', :boolean
            field :purchased, 'Purchased', :boolean
            field :po_number, 'PO number', :string
            field :po_date, 'PO date', :date
            field :vendor, 'Vendor', :string
            field :warranty_date, 'Warranty date', :date
            field :apple_care_id, 'AppleCare ID', :string
            field :lease_date, 'Lease date', :date
            field :purchase_price, 'Purchase price', :string
            field :life_expectancy, 'Life expectancy', :integer
            field :purchasing_account, 'Purchasing account', :string
            field :purchasing_contact, 'Purchasing contact', :secret_string
            field :extension_attributes, 'Extension attributes', :nested, array: true do
              field :definition_id, 'Definition ID', :string
              field :name, 'Name', :string
              field :description, 'Description', :string
              field :enabled, 'Enabled', :boolean
              field :multi_value, 'Multi value', :boolean
              field :values, 'Values', :string, array: true
              field :data_type, 'Data type', :string
              field :options, 'Options', :string, array: true
              field :input_type, 'Input type', :string
            end
          end
          field :disk_encryption, 'Disk encryption', :nested do
            field :boot_partition_encryption_details, 'Boot partition encryption details', :nested do
              field :partition_name, 'Partition name', :string
              field :partition_file_vault2_state, 'Partition file vault2 state', :string
              field :partition_file_vault2_percent, 'Partition file vault2 percent', :integer
            end
            field :individual_recovery_key_validity_status, 'Individual recovery key validity status', :string
            field :institutional_recovery_key_present, 'Institutional recovery key present', :boolean
            field :disk_encryption_configuration_name, 'Disk encryption configuration name', :string
            field :file_vault2_enabled, 'FileVault 2 enabled', :boolean
            field :file_vault2_enabled_user_names, 'FileVault 2 enabled user names', :secret_string, array: true
            field :file_vault2_eligibility_message, 'FileVault 2 eligibility message', :string
          end
          field :extension_attributes, 'Extension attributes', :nested, array: true do
            field :definition_id, 'Definition ID', :string
            field :name, 'Name', :string
            field :description, 'Description', :string
            field :enabled, 'Enabled', :boolean
            field :multi_value, 'Multi value', :boolean
            field :values, 'Values', :string, array: true
            field :data_type, 'Data type', :string
            field :options, 'Options', :string, array: true
            field :input_type, 'Input type', :string
          end
        end
      end

      iteration_state_schema do
        field :page, 'Page', :integer, required: true
        field :fetched, 'Fetched', :integer, required: true
        field :fingerprint, 'Fingerprint', :string, required: true
      end

      run do
        state = helpers.pagination_state
        params = {
          page: state[:page].to_s,
          'page-size': helpers.page_size.to_s,
          sort: COMPUTERS_SORT,
          section: (input[:sections].presence || COMPUTER_SECTIONS).join(','),
        }
        filter = helpers.updated_since_filter(COMPUTERS_UPDATED_FIELD)
        params[:filter] = filter if filter

        response = http_get(helpers.jamf_url(COMPUTERS_API_ROUTE), params)
        backoff_if_needed(response, api_name: 'Jamf')

        helpers.build_jamf_page(helpers.parse_jamf_object(response), state)
      end
    end

    action '019ff02c-617b-7659-8da4-39fe93a638cd' do
      name 'Fetch Mobile Device Inventory'
      avatar '/assets/icons/jamf.svg'
      nested true

      description <<~END_OF_DESCRIPTION
        Returns one page of iPhone, iPad, Apple TV, Apple Watch and Vision Pro inventory from the Jamf Pro API, with keys snake-cased and values exactly as Jamf returned them. Re-invoke while `has_next_page` is true.

        Read `device_type` to know which shape a record has. Jamf documents `iOS`, `tvOS`, `watchOS` and `visionOS`, and also returns `Unknown`. Sections that do not apply to a device type arrive null or are absent from the record altogether.
      END_OF_DESCRIPTION

      input_schema do
        field :sections, 'Sections', :string,
              array: true,
              visibility: 'optional',
              default: MOBILE_DEVICE_SECTIONS,
              hint: 'Inventory sections to request. Jamf returns only the general section when this is empty.',
              enumeration: MOBILE_DEVICE_SECTIONS.map { |section| { id: section, label: section.titleize } }
        field :page_size, 'Page size', :integer,
              visibility: 'optional', default: DEFAULT_PAGE_SIZE, min: 1, max: MAX_PAGE_SIZE,
              hint: 'Mobile devices per page.'
        field :updated_since, 'Updated since', :date_time,
              hint: 'Only return devices whose lastInventoryUpdateDate is at or after this moment. ' \
                    'Leave empty for a full sync.'
        field :exception_handling, 'Exception handling', :string,
              visibility: 'optional', default: DEFAULT_EXCEPTION_HANDLING,
              hint: 'LENIENT returns the page with unprocessable sections set to null. ' \
                    'STRICT makes Jamf fail the whole page instead, one problem device at a time.',
              enumeration: EXCEPTION_HANDLING_MODES.map { |mode| { id: mode, label: mode.titleize } }
      end

      output_schema 'page' do
        field :has_next_page, 'Has next page', :boolean, required: true
        field :total_count, 'Total count', :integer,
              hint: 'What Jamf reported for this request. Empty means Jamf omitted it, not zero devices.'
        field :fetched_count, 'Fetched count', :integer,
              hint: 'Records returned so far across this run.'
        field :results, 'Results', :nested, array: true do
          field :mobile_device_id, 'Mobile device ID', :string
          field :device_type, 'Device type', :string
          field :general, 'General', :nested do
            field :udid, 'UDID', :string
            field :display_name, 'Display name', :string
            field :asset_tag, 'Asset tag', :string
            field :site_id, 'Site ID', :string
            field :last_inventory_update_date, 'Last inventory update date', :date_time
            field :last_contact_date, 'Last contact date', :date_time
            field :os_version, 'OS version', :string
            field :os_rapid_security_response, 'OS rapid security response', :string
            field :os_build, 'OS build', :string
            field :os_supplemental_build_version, 'OS supplemental build version', :string
            field :software_update_device_id, 'Software update device ID', :string
            field :ip_address, 'IP address', :string
            field :managed, 'Managed', :boolean
            field :supervised, 'Supervised', :boolean
            field :device_ownership_type, 'Device ownership type', :string
            field :enrollment_method_prestage, 'Enrollment method prestage', :nested do
              field :mobile_device_prestage_id, 'Mobile device prestage ID', :string
              field :profile_name, 'Profile name', :string
            end
            field :enrollment_session_token_valid, 'Enrollment session token valid', :boolean
            field :last_enrolled_date, 'Last enrolled date', :date_time
            field :mdm_profile_expiration_date, 'MDM profile expiration date', :date_time
            field :time_zone, 'Time zone', :string
            field :declarative_device_management_enabled, 'Declarative device management enabled', :boolean
            field :management_id, 'Management ID', :string
            field :extension_attributes, 'Extension attributes', :nested, array: true do
              field :id, 'ID', :string
              field :name, 'Name', :string
              field :type, 'Type', :string
              field :value, 'Value', :string, array: true
              field :extension_attribute_collection_allowed, 'Extension attribute collection allowed', :boolean
              field :inventory_display, 'Inventory display', :string
            end
            field :last_logged_in_username_self_service, 'Last logged in username self service', :secret_string
            field :last_logged_in_username_self_service_timestamp,
                  'Last logged in username self service timestamp', :date_time
            field :last_logged_in_username_mdm, 'Last logged in username MDM', :secret_string
            field :last_logged_in_username_mdm_timestamp, 'Last logged in username MDM timestamp', :date_time
            field :shared_ipad, 'Shared iPad', :boolean
            field :diagnostic_and_usage_reporting_enabled, 'Diagnostic and usage reporting enabled', :boolean
            field :app_analytics_enabled, 'App analytics enabled', :boolean
            field :resident_users, 'Resident users', :integer
            field :quota_size, 'Quota size', :integer
            field :temporary_session_only, 'Temporary session only', :boolean
            field :temporary_session_timeout, 'Temporary session timeout', :integer
            field :user_session_timeout, 'User session timeout', :integer
            field :synced_to_computer, 'Synced to computer', :integer
            field :maximum_sharedi_pad_users_stored, 'Maximum shared iPad users stored', :integer
            field :last_backup_date, 'Last backup date', :date_time
            field :device_locator_service_enabled, 'Device locator service enabled', :boolean
            field :do_not_disturb_enabled, 'Do not disturb enabled', :boolean
            field :cloud_backup_enabled, 'Cloud backup enabled', :boolean
            field :location_services_for_self_service_mobile_enabled,
                  'Location services for Self Service mobile enabled', :boolean
            field :last_cloud_backup_date, 'Last cloud backup date', :date_time
            field :itunes_store_account_active, 'iTunes Store account active', :boolean
            field :exchange_device_id, 'Exchange device ID', :string
            field :tethered, 'Tethered', :boolean
            field :air_play_password, 'AirPlay password', :secret_string
            field :locales, 'Locales', :string
            field :languages, 'Languages', :string
          end
          field :hardware, 'Hardware', :nested do
            field :capacity_mb, 'Capacity MB', :integer
            field :available_space_mb, 'Available space MB', :integer
            field :used_space_percentage, 'Used space percentage', :integer
            field :battery_level, 'Battery level', :integer
            field :battery_health, 'Battery health', :string
            field :serial_number, 'Serial number', :string
            field :wifi_mac_address, 'Wi-Fi MAC address', :string
            field :bluetooth_mac_address, 'Bluetooth MAC address', :string
            field :modem_firmware_version, 'Modem firmware version', :string
            field :model, 'Model', :string
            field :model_identifier, 'Model identifier', :string
            field :model_number, 'Model number', :string
            field :bluetooth_low_energy_capable, 'Bluetooth low energy capable', :boolean
            field :device_id, 'Device ID', :string
            field :extension_attributes, 'Extension attributes', :nested, array: true do
              field :id, 'ID', :string
              field :name, 'Name', :string
              field :type, 'Type', :string
              field :value, 'Value', :string, array: true
              field :extension_attribute_collection_allowed, 'Extension attribute collection allowed', :boolean
              field :inventory_display, 'Inventory display', :string
            end
          end
          field :user_and_location, 'User and location', :nested do
            field :username, 'Username', :secret_string
            field :real_name, 'Real name', :secret_string
            field :email_address, 'Email address', :secret_string
            field :position, 'Position', :string
            field :phone_number, 'Phone number', :secret_string
            field :department_id, 'Department ID', :string
            field :building_id, 'Building ID', :string
            field :room, 'Room', :string
            field :building, 'Building', :string
            field :department, 'Department', :string
            field :extension_attributes, 'Extension attributes', :nested, array: true do
              field :id, 'ID', :string
              field :name, 'Name', :string
              field :type, 'Type', :string
              field :value, 'Value', :string, array: true
              field :extension_attribute_collection_allowed, 'Extension attribute collection allowed', :boolean
              field :inventory_display, 'Inventory display', :string
            end
          end
          field :purchasing, 'Purchasing', :nested do
            field :purchased, 'Purchased', :boolean
            field :leased, 'Leased', :boolean
            field :po_number, 'PO number', :string
            field :vendor, 'Vendor', :string
            field :apple_care_id, 'AppleCare ID', :string
            field :purchase_price, 'Purchase price', :string
            field :purchasing_account, 'Purchasing account', :string
            field :po_date, 'PO date', :date_time
            field :warranty_expires_date, 'Warranty expires date', :date_time
            field :lease_expires_date, 'Lease expires date', :date_time
            field :life_expectancy, 'Life expectancy', :integer
            field :purchasing_contact, 'Purchasing contact', :secret_string
            field :extension_attributes, 'Extension attributes', :nested, array: true do
              field :id, 'ID', :string
              field :name, 'Name', :string
              field :type, 'Type', :string
              field :value, 'Value', :string, array: true
              field :extension_attribute_collection_allowed, 'Extension attribute collection allowed', :boolean
              field :inventory_display, 'Inventory display', :string
            end
          end
          field :security, 'Security', :nested do
            field :data_protected, 'Data protected', :boolean
            field :block_level_encryption_capable, 'Block level encryption capable', :boolean
            field :file_level_encryption_capable, 'File level encryption capable', :boolean
            field :passcode_present, 'Passcode present', :boolean
            field :passcode_compliant, 'Passcode compliant', :boolean
            field :passcode_compliant_with_profile, 'Passcode compliant with profile', :boolean
            field :hardware_encryption, 'Hardware encryption', :integer
            field :activation_lock_enabled, 'Activation lock enabled', :boolean
            field :jail_break_detected, 'Jailbreak detected', :boolean
            field :attestation_status, 'Attestation status', :string
            field :last_attestation_attempt_date, 'Last attestation attempt date', :date_time
            field :last_successful_attestation_date, 'Last successful attestation date', :date_time
            field :passcode_lock_grace_period_enforced_seconds,
                  'Passcode lock grace period enforced seconds', :integer
            field :personal_device_profile_current, 'Personal device profile current', :boolean
            field :lost_mode_enabled, 'Lost mode enabled', :boolean
            field :lost_mode_persistent, 'Lost mode persistent', :boolean
            field :lost_mode_message, 'Lost mode message', :string
            field :lost_mode_phone_number, 'Lost mode phone number', :secret_string
            field :lost_mode_footnote, 'Lost mode footnote', :string
            field :lost_mode_location, 'Lost mode location', :nested do
              field :last_location_update, 'Last location update', :date_time
              field :lost_mode_location_horizontal_accuracy_meters,
                    'Lost mode location horizontal accuracy meters', :float
              field :lost_mode_location_vertical_accuracy_meters,
                    'Lost mode location vertical accuracy meters', :float
              field :lost_mode_location_altitude_meters, 'Lost mode location altitude meters', :float
              field :lost_mode_location_speed_meters_per_second,
                    'Lost mode location speed meters per second', :float
              field :lost_mode_location_course_degrees, 'Lost mode location course degrees', :float
              field :lost_mode_location_timestamp, 'Lost mode location timestamp', :string
            end
            field :bootstrap_token_escrowed, 'Bootstrap token escrowed', :string
            # Returned by Jamf Pro 11.31.1 but absent from the tenant's own /api/schema document,
            # so these two came from the live response rather than the spec. Null on every device
            # in the verification tenant, so their types are inferred from their names: a field
            # named for a bootstrap token is treated as a secret until proven otherwise.
            field :bootstrap_token, 'Bootstrap token', :secret_string
            field :lost_mode_enabled_date, 'Lost mode enabled date', :date_time
          end
          field :network, 'Network', :nested do
            field :cellular_technology, 'Cellular technology', :string
            field :voice_roaming_enabled, 'Voice roaming enabled', :boolean
            field :imei, 'IMEI', :string
            field :iccid, 'ICCID', :string
            field :meid, 'MEID', :string
            field :eid, 'EID', :string
            field :carrier_settings_version, 'Carrier settings version', :string
            field :current_carrier_network, 'Current carrier network', :string
            field :current_mobile_country_code, 'Current mobile country code', :string
            field :current_mobile_network_code, 'Current mobile network code', :string
            field :home_carrier_network, 'Home carrier network', :string
            field :home_mobile_country_code, 'Home mobile country code', :string
            field :home_mobile_network_code, 'Home mobile network code', :string
            field :data_roaming_enabled, 'Data roaming enabled', :boolean
            field :roaming, 'Roaming', :boolean
            field :personal_hotspot_enabled, 'Personal hotspot enabled', :boolean
            field :phone_number, 'Phone number', :secret_string
            field :preferred_voice_number, 'Preferred voice number', :secret_string
          end
          field :extension_attributes, 'Extension attributes', :nested, array: true do
            field :id, 'ID', :string
            field :name, 'Name', :string
            field :type, 'Type', :string
            field :value, 'Value', :string, array: true
            field :extension_attribute_collection_allowed, 'Extension attribute collection allowed', :boolean
            field :inventory_display, 'Inventory display', :string
          end
        end
      end

      iteration_state_schema do
        field :page, 'Page', :integer, required: true
        field :fetched, 'Fetched', :integer, required: true
        field :fingerprint, 'Fingerprint', :string, required: true
      end

      run do
        state = helpers.pagination_state
        params = {
          page: state[:page].to_s,
          'page-size': helpers.page_size.to_s,
          sort: MOBILE_DEVICES_SORT,
          section: (input[:sections].presence || MOBILE_DEVICE_SECTIONS).join(','),
          'exception-handling': input[:exception_handling].presence || DEFAULT_EXCEPTION_HANDLING,
        }
        filter = helpers.updated_since_filter(MOBILE_DEVICES_UPDATED_FIELD)
        params[:filter] = filter if filter

        response = http_get(helpers.jamf_url(MOBILE_DEVICES_API_ROUTE), params)
        backoff_if_needed(response, api_name: 'Jamf')

        helpers.build_jamf_page(helpers.parse_jamf_object(response), state)
      end
    end

    action '01a0433b-a88a-7133-8125-16d40356c087' do
      name 'Fetch Sites'
      avatar '/assets/icons/jamf.svg'

      description <<~END_OF_DESCRIPTION
        Returns every Jamf site in a single call. `GET /api/v1/sites` accepts no paging, sorting or filtering parameters, so there is nothing to configure and nothing to iterate.

        Mobile device records carry `general.siteId` with no site name attached, so a runbook that needs a location has to join against this list. Computers already carry `general.site` as an id and name pair and do not need it.
      END_OF_DESCRIPTION

      output_schema do
        field :sites, 'Sites', :nested, array: true do
          field :id, 'ID', :string
          field :division_id, 'Division ID', :string
          field :name, 'Name', :string
        end
      end

      run do
        response = http_get(helpers.jamf_url(SITES_API_ROUTE))
        backoff_if_needed(response, api_name: 'Jamf')

        sites = helpers.parse_jamf_array(response)
        log('Fetched %<count>s Jamf sites', { count: sites.size })
        [{ output: { sites: camel_to_snake(sites) } }]
      end
    end

    helper :api_base do
      raw = outbound_connection.config&.dig(:credentials, :jamf_url).to_s.strip
      url = raw.sub(%r{/+\z}, '').chomp('/api').sub(%r{/+\z}, '')
      fail_job!("Jamf Pro URL must start with https://, got '#{raw}'") unless url.start_with?('https://')

      "#{url}#{API_BASE_PATH}"
    end

    helper :jamf_url do |route|
      "#{helpers.api_base}#{route}"
    end

    # min: 1, max: MAX_PAGE_SIZE on the input field are enforced by the input mapping before the
    # run block executes, so this only has to supply the default.
    helper :page_size do
      input[:page_size] || DEFAULT_PAGE_SIZE
    end

    helper :updated_since_utc do
      raw = input[:updated_since]
      if raw.blank?
        nil
      else
        parsed = raw.to_datetime.utc
        now = Time.now.utc
        if parsed > now
          log('Updated since %<since>s is in the future, clamping to now', { since: parsed.iso8601 })
          parsed = now
        end

        parsed
      end
    end

    helper :updated_since_filter do |field|
      since = helpers.updated_since_utc
      if since.nil?
        nil
      else
        filter = "#{field}>=#{since.iso8601(3)}"
        log('Jamf incremental filter: %<filter>s', { filter: filter })
        filter
      end
    end

    helper :request_fingerprint do
      Digest::SHA256.hexdigest([Array(input[:sections]).map(&:to_s).sort,
                                input[:updated_since].to_s,
                                input[:exception_handling].to_s,
                                helpers.page_size,].to_json)
    end

    helper :pagination_state do
      fingerprint = helpers.request_fingerprint
      page = iteration_state_value(:page)

      if page.nil?
        { page: 0, fetched: 0, fingerprint: fingerprint }
      else
        unless iteration_state_value(:fingerprint) == fingerprint
          fail_job!('Jamf pagination inputs changed between pages, restart the sync from the first page')
        end

        { page: [page.to_i, 0].max,
          fetched: [iteration_state_value(:fetched).to_i, 0].max,
          fingerprint: fingerprint, }
      end
    end

    helper :parse_jamf_body do |response|
      if [401, 403].include?(response.status)
        fail_job!("Jamf authentication error: #{response.status} '#{response.body}'")
      end
      fail_job!("Jamf HTTP error: #{response.status} '#{response.body}'") unless response.status == 200

      parse_json_response(response.body,
                          error_message: "Jamf response was not valid JSON: '#{response.body}'")
    end

    helper :parse_jamf_object do |response|
      parsed = helpers.parse_jamf_body(response)
      fail_job!("Jamf response was not a JSON object: '#{response.body}'") unless parsed.is_a?(Hash)

      parsed.with_indifferent_access
    end

    helper :parse_jamf_array do |response|
      parsed = helpers.parse_jamf_body(response)
      fail_job!("Jamf response was not a JSON array: '#{response.body}'") unless parsed.is_a?(Array)

      parsed
    end

    helper :build_jamf_page do |body, state|
      raw_results = body[:results]
      unless raw_results.nil? || raw_results.is_a?(Array)
        fail_job!("Jamf returned results as #{raw_results.class}, expected an array")
      end
      results = raw_results || []

      fetched = state[:fetched] + results.size
      has_more = results.any?
      self.iteration_state_value = if has_more
                                     { page: state[:page] + 1, fetched: fetched,
                                       fingerprint: state[:fingerprint], }
                                   end

      helpers.log_unmodelled_keys(results, state[:page])

      [{ output: { has_next_page: has_more,
                   total_count: body[:totalCount]&.to_i,
                   fetched_count: fetched,
                   results: camel_to_snake(results), },
         schema_reference: 'page', }]
    end

    helper :unmodelled_keys_in do |value, fields|
      declared = fields.to_h { |field| [field.id.to_s, field] }
      records = value.is_a?(Array) ? value : [value]
      records.flat_map do |record|
        next [] unless record.is_a?(Hash)

        snake = camel_to_snake(record)
        snake.keys.flat_map do |key|
          field = declared[key.to_s]
          next [key.to_s] unless field
          next [] if field.fields.blank?

          helpers.unmodelled_keys_in(snake[key], field.fields).map { |nested| "#{key}.#{nested}" }
        end
      end.uniq
    end

    # Jamf returns every top-level section whether or not it was requested, setting the unrequested
    # ones to null, so comparing all sections against the schema reported 14 we deliberately do not
    # model on every single run. Only that padding is dropped. A null nested key is still a key this
    # action does not model, and 110 of the 111 computers on the verified fleet carry one.
    helper :log_unmodelled_keys do |results, page|
      if page == 0
        requested = results.select { |record| record.is_a?(Hash) }.map(&:compact)
        unknown = helpers.unmodelled_keys_in(requested, action.output_schema('page').field(:results).fields)
        log('Jamf returned keys this action does not model: %<keys>s', { keys: unknown.join(', ') }) if
          unknown.any?
      end
    end
  end
end
