module IPaaS
  module Connector
    module Common
      module ResolveScope
        KEY = :ipaas_resolve_scope

        module_function

        def current
          Thread.current[KEY] ||= Object.new
        end

        def reset
          Thread.current[KEY] = Object.new
        end

        def stamp(value)
          value.nil? ? nil : [current, value].freeze
        end

        def read(entry)
          return nil unless entry.is_a?(Array) && entry.first.equal?(current)

          entry.last
        end
      end
    end
  end
end
