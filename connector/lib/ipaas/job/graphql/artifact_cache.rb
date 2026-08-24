require 'digest'
require 'securerandom'

module IPaaS
  module Job
    module GraphQL
      # Connector-agnostic GraphQL caching: the derived-artifact bundle, its generation token,
      # the root-field options cache, and the digest/validation helpers. Each takes the outbound
      # +connection+ (+nil+ for an unconfigured action), which supplies both the expiring cache and
      # the durable store, plus already-resolved values, so connectors compose them through thin DSL
      # wrappers. Reads fail closed on an absent generation, so an orphaned entry is never served.
      module ArtifactCache
        extend IPaaS::Connector::Common::ProcRules::ProcSafe

        proc_safe :gql_cache_read, :gql_cache_write, :gql_cache_clear,
                  :gql_invalidate,
                  :gql_load_bundle, :gql_write_bundle_part,
                  :gql_read_root_options, :gql_write_root_options, :gql_seed_root_options,
                  :gql_warm_for_regeneration?,
                  :gql_read_schema_error, :gql_write_schema_error, :gql_clear_schema_error,
                  :gql_schema_error_cause, :gql_selector_notice

        # Derived artifacts persist a week so the warm path serves without re-introspecting;
        # a generation bump invalidates them sooner.
        BUNDLE_TTL = 7.days.to_i

        # On the connection's durable store, not in its cache: an anchor that expires before the
        # entries it gates fails every derived read closed while they are still valid (#80566194).
        GENERATION_KEY = 'gql_artifact_generation'.freeze

        # Removable once BUNDLE_TTL has elapsed since release, when no cached token can still be live.
        LEGACY_GENERATION_KEY = 'gql_bundle_gen'.freeze

        # Under a fixed key rather than the credential-derived negative-cache key, so a schema
        # build can read it without decrypting secrets.
        SCHEMA_ERROR_KEY = 'gql_schema_error'.freeze
        SCHEMA_ERROR_TTL = 10.minutes.to_i
        SCHEMA_ERROR_REASON_LIMIT = 200

        # 4xx codes the connection cannot be edited to fix, so they must not reach the
        # blame-the-connection branch below.
        TRANSIENT_STATUSES = [408, 429].freeze

        UNCONFIGURED_NOTICE = {
          notice: 'Outbound Connection is not configured correctly.',
          notice_type: 'error',
          notice_action: 'edit_connection',
        }.freeze

        class << self
          # A +nil+ connection (unconfigured action) is intentional: reads ⇒ nil, writes/clears ⇒ no-op.
          def gql_cache_read(connection, key)
            connection&.cache_read(key)
          end

          def gql_cache_write(connection, key, value, ttl)
            connection ? connection.cache_write(key, value, ttl) : value
          end

          def gql_cache_clear(connection, key)
            connection&.cache_clear(key)
          end

          def gql_durable_store(connection)
            connection&.store
          end

          def gql_bundle_generation(connection)
            token = gql_durable_store(connection)&.read(GENERATION_KEY)
            token.presence || gql_adopt_legacy_generation(connection)
          end

          # Returned, never written: promoting it is a read-modify-write that can land after a
          # concurrent bump and revive the entries that bump orphaned.
          def gql_adopt_legacy_generation(connection)
            gql_cache_read(connection, LEGACY_GENERATION_KEY).presence&.to_s
          end

          # Opaque, never derived from the current value: an increment over an empty read
          # (+nil.to_i + 1+ writes 1 over a 3) recomputes a generation that was already live.
          def gql_bump_bundle_generation(connection)
            SecureRandom.hex(8).tap { |token| gql_durable_store(connection)&.write(GENERATION_KEY, token) }
          end

          # The Refresh schema reset: clears the given keys (the cached schema and the negative
          # cache) and bumps the generation, orphaning every derived bundle and root-options
          # entry so the rebuild repopulates under the new generation.
          def gql_invalidate(connection, *clear_keys)
            clear_keys.each { |key| gql_cache_clear(connection, key) }
            gql_clear_schema_error(connection)
            gql_bump_bundle_generation(connection)
          end

          # Returns the bundle part for a selection under the current generation, or +nil+ so the
          # caller falls back to the schema. The selection-presence gate stays connector-side.
          def gql_load_bundle(connection, operation, part, selection_name:, include_fields:, required_keys:)
            gen = gql_bundle_generation(connection)
            return nil if gen.nil? # fail closed: no generation ⇒ never read an orphan

            key = gql_bundle_cache_key(operation, part, selection_name, include_fields, gen)
            bundle = gql_cache_read(connection, key)
            return nil unless bundle.is_a?(Hash)
            # reject a shape-incompatible entry (older / cross-version) so the caller rebuilds
            return nil unless required_keys.all? { |k| bundle.key?(k) }

            descriptor_key = part == 'in' ? 'input_fields' : 'output_fields'
            return nil unless gql_valid_descriptor_list?(bundle[descriptor_key])

            bundle
          end

          def gql_write_bundle_part(connection, operation, part, selection_name:, include_fields:, bundle:)
            gen = gql_bundle_generation(connection) || gql_bump_bundle_generation(connection)
            gql_cache_write(connection, gql_bundle_cache_key(operation, part, selection_name, include_fields, gen),
                            bundle, BUNDLE_TTL)
            bundle
          end

          def gql_read_root_options(connection, operation)
            gen = gql_bundle_generation(connection)
            return nil if gen.nil? # fail closed

            cached = gql_cache_read(connection, gql_root_options_cache_key(operation, gen))
            return nil if cached.nil?

            cached.map { |opt| { id: opt['id'], label: opt['label'] } }
          end

          def gql_write_root_options(connection, operation, options)
            gen = gql_bundle_generation(connection) || gql_bump_bundle_generation(connection)
            gql_cache_write(connection, gql_root_options_cache_key(operation, gen), options, BUNDLE_TTL)
          end

          # Seeds the selector enumeration the first time a schema yields one, so it survives the
          # schema's own shorter TTL even on an action where nothing was ever selected.
          def gql_seed_root_options(connection, operation, options)
            return if options.blank? || !gql_read_root_options(connection, operation).nil?

            gql_write_root_options(connection, operation, options)
          end

          # True when a regeneration can skip fetching the schema: the selector options are
          # cached and, once a selection is made, both bundle parts are present.
          def gql_warm_for_regeneration?(connection, operation, selection_present:, selection_name:, include_fields:,
                                         required_keys_in:, required_keys_out:)
            return false if gql_read_root_options(connection, operation).nil?
            return true unless selection_present

            !gql_load_bundle(connection, operation, 'in',
                             selection_name: selection_name, include_fields: include_fields,
                             required_keys: required_keys_in).nil? &&
              !gql_load_bundle(connection, operation, 'out',
                               selection_name: selection_name, include_fields: include_fields,
                               required_keys: required_keys_out).nil?
          end

          def gql_read_schema_error(connection)
            gql_cache_read(connection, SCHEMA_ERROR_KEY)
          end

          # Which part of the connection a non-200 introspection response implicates. The status
          # picks the remedy and is never itself rendered.
          def gql_schema_error_cause(status)
            return :transient if TRANSIENT_STATUSES.include?(status)

            case status
            when 401, 403 then :credentials
            when 404, 405 then :address
            when 400..499 then :rejected
            else :transient
            end
          end

          # +reason+ is recorded for support and never rendered: these messages carry upstream
          # response bodies, which users must not see.
          def gql_write_schema_error(connection, message, cause:)
            gql_cache_write(connection, SCHEMA_ERROR_KEY,
                            { 'reason' => message.to_s[0, SCHEMA_ERROR_REASON_LIMIT],
                              'cause' => cause.to_s, },
                            SCHEMA_ERROR_TTL)
          end

          def gql_clear_schema_error(connection)
            gql_cache_clear(connection, SCHEMA_ERROR_KEY)
          end

          def gql_selector_notice(connection, source)
            return UNCONFIGURED_NOTICE if connection.nil?

            error = gql_read_schema_error(connection)
            return gql_schema_pending_notice(source) if error.nil?

            case error['cause']
            when 'credentials' then gql_credentials_rejected_notice(source)
            when 'address' then gql_address_unanswered_notice
            when 'rejected' then gql_request_rejected_notice(source)
            else gql_schema_unavailable_notice(source)
            end
          end

          def gql_credentials_rejected_notice(source)
            gql_connection_notice("Could not read the schema: #{source} rejected the credentials " \
                                  'in the Outbound Connection.')
          end

          def gql_address_unanswered_notice
            gql_connection_notice('Could not read the schema: nothing answered at the address in ' \
                                  'the Outbound Connection.')
          end

          def gql_request_rejected_notice(source)
            gql_connection_notice("Could not read the schema: #{source} rejected the request. " \
                                  'Check the Outbound Connection.')
          end

          def gql_connection_notice(message)
            { notice: message, notice_type: 'error', notice_action: 'edit_connection' }
          end

          def gql_schema_unavailable_notice(source)
            { notice: "Could not reach #{source} to load the schema. This is usually temporary — " \
                      'reopen this step in a moment to try again.',
              notice_type: 'info', notice_action: nil, }
          end

          def gql_schema_pending_notice(source)
            { notice: "The schema from #{source} has not loaded yet. Reopen this step to load it.",
              notice_type: 'info', notice_action: nil, }
          end

          # Digest over the inputs that fully determine a bundle part.
          def gql_bundle_cache_key(operation, part, selection_name, include_fields, gen)
            digest = Digest::SHA256.hexdigest(
              [operation.to_s, selection_name.to_s, gql_stable_json(include_fields)].join("\n"),
            )
            "gql_bundle_#{part}_#{gen}_#{digest}"
          end

          def gql_root_options_cache_key(operation, gen)
            "gql_root_fields_#{operation}_#{gen}"
          end

          # Canonical JSON with sorted string keys: logically-equal hashes serialize identically,
          # and an explicit false leaf stays distinct from an absent key (+{a: false}+ ≠ +{}+).
          def gql_stable_json(value)
            case value
            when Hash
              normalized = value.transform_keys(&:to_s)
              pairs = normalized.keys.sort.map { |k| "#{k.to_json}:#{gql_stable_json(normalized[k])}" }
              "{#{pairs.join(',')}}"
            when Array
              "[#{value.map { |v| gql_stable_json(v) }.join(',')}]"
            else
              value.to_json
            end
          end

          # Whether a descriptor list is structurally restorable, so a malformed cross-version
          # bundle fails closed in +gql_load_bundle+ instead of raising mid-restore.
          def gql_valid_descriptor_list?(value)
            value.is_a?(Array) && value.all? { |descriptor| valid_descriptor?(descriptor) }
          end

          private

          def valid_descriptor?(descriptor)
            descriptor.is_a?(Hash) &&
              descriptor['id'].is_a?(String) && descriptor['label'].is_a?(String) &&
              descriptor['type'].is_a?(String) && valid_descriptor_enumeration?(descriptor) &&
              (!descriptor.key?('fields') || gql_valid_descriptor_list?(descriptor['fields']))
          end

          def valid_descriptor_enumeration?(descriptor)
            return true unless descriptor.key?('enumeration')

            descriptor['enumeration'].is_a?(Array) &&
              descriptor['enumeration'].all? { |e| e.is_a?(Hash) && e.key?('id') && e.key?('label') }
          end
        end
      end
    end
  end
end
