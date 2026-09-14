module IPaaS
  module Job
    module Delegation
      module HelpersRef
        extend ActiveSupport::Concern

        included do
          # Never nil — see `Helpers.empty_for_proc`.
          def helpers
            own_helpers || IPaaS::Connector::Common::Helpers.empty_for_proc
          end

          private

          def own_helpers
            owner = helpers_owner
            return owner.helpers if owner

            try(:connector)&.helpers
          end

          def helpers_owner
            return action_template if self.is_a?(IPaaS::Connector::Action)
            return trigger_template if self.is_a?(IPaaS::Connector::Trigger)

            connection_definition if self.is_a?(IPaaS::Connector::Connection)
          end
        end
      end
    end
  end
end

IPaaS::Job::Context.extension(IPaaS::Job::Delegation::HelpersRef)
