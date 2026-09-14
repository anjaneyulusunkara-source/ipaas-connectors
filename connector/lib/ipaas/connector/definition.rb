module IPaaS
  module Connector
    class Definition
      class << self
        def connector(uuid, &block)
          return @connector unless block
          raise IPaaS::Error, 'Only one connector per class allowed' if @connector

          @connector = IPaaS::Connector::Connector.new(uuid).tap do |c|
            c.instance_eval(&block)
          end
        end

        # A connector class is shared across threads, so its constants must be immutable to their
        # leaves. Module-bound so a singleton override of `constants` cannot shorten the list; what
        # keeps a constant off that list entirely is the shape check.
        #
        # Source order is dependency order, so each value is walked with its references already
        # immutable and no walk descends deeper than one assignment's own nesting. Unsorted, a chain
        # of back-references is a single walk deep enough to overflow a pooled thread's stack. The
        # line ordering is safe because ConnectorShape refuses two constants on one line.
        def make_constants_shareable(klass)
          constants = ::Module.instance_method(:constants)
          const_get = ::Module.instance_method(:const_get)
          defined_at = ::Module.instance_method(:const_source_location)
          names = constants.bind_call(klass, false)
          names.sort_by! { |name| defined_at.bind_call(klass, name, false)&.last || 0 }
          names.each { |name| IPaaS.make_shareable(const_get.bind_call(klass, name, false)) }
        end
      end
    end
  end
end
