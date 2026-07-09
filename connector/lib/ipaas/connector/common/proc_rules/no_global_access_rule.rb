module IPaaS
  module Connector
    module Common
      module ProcRules
        class NoGlobalAccessRule < ProcRule
          NOT_ALLOWED_NAMES = Set.new(Object.constants
                                    .excluding(:IO, :JWT, :URI, :JSON, :YAML)
                                    .select { |n| n.to_s.upcase == n.to_s } +
                                      [:RUBY_PATCH_LEVEL, :DATA, :ENVx])
                                 .freeze

          # Full constant paths that are safe despite their leaf name colliding with a blocked global.
          # The same leaf reached through any other path stays blocked.
          ALLOWED_CONST_PATHS = Set[
            [:IPaaS, :Job, :Outbound, :HTTP].freeze, # our own, used in Xurrent App Connector
          ].freeze

          def initialize(...)
            super
            @const_reported = []
            @global_vars_reported = []
          end

          def on_lvasgn(node)
            _, value = *node
            visit(value)
          end

          def on_dstr(node)
            visit(node)
          end

          def on_gvar(node)
            target, = *node
            return if @global_vars_reported.include?(target)

            @global_vars_reported << target
            on_invalid.call("Access to '#{target}' not allowed.")
          end

          def on_const(node)
            report_const_access(node)
          end

          def on_send(node)
            target, _, *params = *node
            if target&.type == :const && report_access?(target)
              name = target.children[1]
              on_invalid.call("Calling methods on '#{name}' not allowed.")
              return
            end
            params.each { |p| visit(p) }
          end

          def visit(node)
            return if node.try(:type) == :const && report_const_access(node)
            return unless node.is_a?(RuboCop::AST::Node)

            node.to_a.each { |n| visit(n) }
          end

          # Reports a blocked constant read; returns the reported name, or nil if allowed.
          def report_const_access(node)
            return unless report_access?(node)

            name = node.children[1]
            on_invalid.call("Access to '#{name}' not allowed.")
            name
          end

          def report_access?(target)
            # Block by constant name regardless of namespace scope.
            # Fail closed, exempting only ALLOWED_CONST_PATHS.
            name = target.children[1]
            return false if @const_reported.include?(name) || NOT_ALLOWED_NAMES.exclude?(name)
            return false if ALLOWED_CONST_PATHS.include?(const_path(target))

            @const_reported << name
            true
          end

          # Constant path as symbols, root-first (`IPaaS::Job::Outbound::HTTP` → %i[IPaaS Job
          # Outbound HTTP]), or nil when the scope is not a pure constant path.
          def const_path(node)
            parts = []
            while node.is_a?(RuboCop::AST::Node) && node.type == :const
              parts.unshift(node.children[1])
              node = node.children[0]
            end
            parts if node.nil? || (node.is_a?(RuboCop::AST::Node) && node.type == :cbase)
          end
        end
      end
    end
  end
end
