module IPaaS
  module Connector
    module Common
      class UnresolvedNode
        CHECKED_NODES_KEY = :ipaas_unresolved_checked_nodes

        attr_reader :unresolved_class, :message, :node

        class << self
          def for_node(node)
            reject_aliases!(node)
            new(node.tag, node)
          end

          def forget_checked_nodes!
            Thread.current[CHECKED_NODES_KEY] = nil
          end

          def within?(value, seen = nil)
            return true if value.is_a?(self)

            case value
            when Hash, Array then within_collection?(value, seen || new_visited_set)
            else within_ivars?(value, seen)
            end
          end

          def symbolize(value)
            return value if within?(value)

            value&.to_s&.presence&.to_sym
          end

          def all_within(value)
            [].tap { |found| each_within(value) { |node| found << node } }
          end

          private

          def new_visited_set
            Set.new.compare_by_identity
          end

          def within_collection?(value, seen)
            return false unless seen.add?(value)

            case value
            when Hash then value.any? { |key, nested| within?(key, seen) || within?(nested, seen) }
            else value.any? { |nested| within?(nested, seen) }
            end
          end

          def within_ivars?(value, seen = nil)
            return false unless Serializer::ALLOWED_CLASS_SET.include?(value.class)

            seen ||= new_visited_set
            return false unless seen.add?(value)

            value.instance_variables.any? { |name| within?(value.instance_variable_get(name), seen) }
          end

          def each_within(value, seen = nil, &block)
            return yield(value) if value.is_a?(self)

            case value
            when Hash, Array then each_within_collection(value, seen || new_visited_set, &block)
            else each_within_ivars(value, seen, &block)
            end
          end

          def each_within_collection(value, seen, &block)
            return unless seen.add?(value)

            case value
            when Hash
              value.each do |key, nested|
                each_within(key, seen, &block)
                each_within(nested, seen, &block)
              end
            else value.each { |nested| each_within(nested, seen, &block) }
            end
          end

          def each_within_ivars(value, seen = nil, &block)
            return unless Serializer::ALLOWED_CLASS_SET.include?(value.class)

            seen ||= new_visited_set
            return unless seen.add?(value)

            value.instance_variables.each { |name| each_within(value.instance_variable_get(name), seen, &block) }
          end

          def reject_aliases!(node)
            return unless checked_nodes.add?(node)

            case node
            when Psych::Nodes::Alias then raise Psych::AliasesNotEnabled
            when Psych::Nodes::Sequence, Psych::Nodes::Mapping
              node.children.each { |child| reject_aliases!(child) }
            when Psych::Nodes::Scalar then nil
            else raise IPaaS::Error, "Cannot capture #{node.class}"
            end
          end

          def checked_nodes
            Thread.current[CHECKED_NODES_KEY] ||= Set.new.compare_by_identity
          end
        end

        def initialize(tag, node)
          @coder_tag = tag
          @node = node
          @unresolved_class = tag.to_s.delete_prefix('!ruby/object:').delete_prefix('!')
          @message = "could not load value of type '#{@unresolved_class}'"
        end

        def encode_with(_coder)
          raise IPaaS::Error, "#{@message}; write it with Serializer.dump to keep the original node"
        end

        def as_json(_options = nil)
          nil
        end

        def to_s
          @message
        end

        def <=>(other)
          case other
          when UnresolvedNode then message <=> other.message
          when String, Symbol then message <=> other.to_s
          end
        end

        def inspect
          "#<IPaaS::Connector::Common::UnresolvedNode #{@unresolved_class}>"
        end
      end
    end
  end
end
