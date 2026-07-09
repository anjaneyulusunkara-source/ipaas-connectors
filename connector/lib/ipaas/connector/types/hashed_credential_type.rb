module IPaaS
  module Connector
    module Types
      module HashedCredentialType
        include IPaaS::Connector::Types::Base

        SCHEMA_REFERENCE = 'hashed-credential-type'.freeze

        class << self
          def ruby_class
            IPaaS::Encryption::HashedCredential
          end

          # Resolve WRAPS an already-derived {salt,hash} Hash; it NEVER derives from a
          # raw String (PBKDF2 with a random salt is non-deterministic across re-resolves)
          # and it must NEVER raise. On a malformed-but-shaped record the strict from_h!
          # is rescued and the raw value is returned UNCHANGED, so the downstream type
          # check fails predictably rather than resolution 500ing.
          def resolve(resolved_value, context: nil)
            return nil if resolved_value.nil?
            return resolved_value if resolved_value.is_a?(ruby_class)

            return IPaaS::Encryption::HashedCredential.from_h!(resolved_value) if derived_hash?(resolved_value)

            IPaaS::Connector::Types::Base.fallback_resolve(resolved_value)
          rescue StandardError
            resolved_value
          end

          # Config-correctness gate for the paths that bypass apply_value (fixed/API/YAML).
          # By the time valid? runs, resolve has already turned a shaped Hash into a
          # HashedCredential OBJECT, so re-check the resolved object's content strictly
          # (mirrors SecretStringType#valid?). Normalize both the object and a raw Hash
          # to a record, then route through the SINGLE strict gate.
          def valid?(value, errors = [])
            return true if value.blank?

            record = value.is_a?(ruby_class) ? value.to_h : value
            IPaaS::Encryption::HashedCredential.from_h!(record)
            true
          rescue StandardError
            errors << 'Expected a derived hashed-credential value (…salt/hash…).'
            false
          end

          def nested?
            true
          end

          def variable_resolvable?
            true
          end

          # A real derived record (from a discarded 22-char random plaintext) so
          # the example passes the strict from_h! shape/length validation.
          def example(_field)
            {
              'salt' => 'PXl7+C0etitfkgh39B97ig==',
              'hash' => '8EYPre/gfPgldBpwSr64YbftlB1Hn+Ek8BX4jTf/vOg=',
            }
          end

          def schema
            @schema ||= IPaaS::Connector::Schema.new(SCHEMA_REFERENCE) do
              # hidden: derived material is written by the credential input,
              # never mapped by hand.
              field :salt, 'Salt', :string,
                    required: true,
                    visibility: 'hidden'

              field :hash, 'Hash', :string,
                    required: true,
                    visibility: 'hidden'
            end
          end

          private

          def derived_hash?(value)
            value.is_a?(Hash) && value.with_indifferent_access.values_at(:salt, :hash).all?(&:present?)
          end
        end
      end
    end
  end
end

IPaaS::Connector::Types.register(IPaaS::Connector::Types::HashedCredentialType)
