module IPaaS
  module Connector
    module Authentication
      module Inbound
        class << self
          def register(key, module_klass)
            helper = module_klass.validate_request_helper(nil)
            setup_info_helper = module_klass.setup_info_helper(nil)
            errors = collect_validation_errors(module_klass, helper, setup_info_helper)
            raise ArgumentError, "#{module_klass} is not valid. Errors: #{errors}" if errors.present?

            (@validators ||= {})[key] = module_klass
          end

          def keys
            @validators.keys
          end

          def module(key)
            @validators[key]
          end

          private

          def collect_validation_errors(module_klass, helper, setup_info_helper)
            # Without a validate block the module would perform no request
            # validation at all — refuse at registration rather than silently
            # skipping auth checks at request time.
            return ['a validate block is required'] if helper.nil?

            to_check = [helper, setup_info_helper, module_klass.helpers].compact
            return [] if to_check.map(&:valid?).all?

            to_check.flat_map(&:errors).compact
          end
        end

        module Extension
          extend ActiveSupport::Concern

          # rubocop:disable Metrics/BlockLength
          class_methods do
            def helpers
              @helpers ||= IPaaS::Connector::Common::Helpers.new
            end

            def helper(name, &block)
              helpers.define_helper(name, &block)
            end

            def validate(&block)
              @validator = block
            end

            def setup_info(&block)
              @setup_info = block
            end

            def validate_request_helper(binding)
              return unless @validator

              IPaaS::Connector::Common::ProcHelper.new(binding, @validator)
            end

            def setup_info_helper(binding)
              return unless @setup_info

              IPaaS::Connector::Common::ProcHelper.new(binding, @setup_info)
            end

            def validate_request(binding, request)
              validate_request_helper(binding).tap do |top_level_helper|
                next unless top_level_helper

                helpers.copy_to(binding)
                top_level_helper.execute(request)
              end
            end

            def setup_info_for(binding)
              setup_info_helper(binding).tap do |top_level_helper|
                next unless top_level_helper

                helpers.copy_to(binding)
                return top_level_helper.execute
              end
              nil
            end
          end
          # rubocop:enable Metrics/BlockLength
        end
      end
    end
  end
end
