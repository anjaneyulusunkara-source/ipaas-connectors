module IPaaS
  module Connector
    module Common
      module ProcRules
        class NoGlobalAccessRule < ProcRule
          NOT_ALLOWED_CLASS_NAMES = [
            :File, :FileTest, :FileUtils, :Dir, :Kernel, :ObjectSpace, :Marshal, :Binding, :Etc,
            :Method, :UnboundMethod, :Process, :Thread, :Fiber, :Ractor, :RubyVM, :TracePoint,
            :CSV, :Gem, :Bundler, :Thor, :ViteRuby, :Nokogiri,
            :RequestStore, :ProcHelper, :ProcRules, :SourceParser, :Ripper, :Prism,
            :Socket, :BasicSocket, :IPSocket, :TCPSocket, :TCPServer, :UDPSocket, :UNIXSocket, :UNIXServer,
            :ActiveSupport, :ActiveJob, :ActiveModel, :ActiveRecord, :ActionController,
            :ActionDispatch, :ActionPack, :ActionView, :Rails, :SolidQueue,
            :Redis, :RedisClient, :Aws, :Seahorse, :Parallel, :ApplicationRecord,
            :Account, :AccountUser, :AuditEvent, :BulkTestReport,
            :ConnectorAvatarBlob, :ConnectorUsageSnapshot, :EnvironmentVariableValue, :ErrorLog, :Favorite,
            :Frame, :Job, :JobConnectorTask, :JobStateEntry, :LogEntry, :ProvisionedComponent, :RateLimitBlock,
            :RateLimitEvent, :RateLimitUsageSnapshot, :RunbookRecord, :Schedule, :Solution, :SolutionBranch,
            :SolutionNamedVersion, :SolutionStoreEntry, :StepPath, :StepPathIteration, :StepPathIterator,
            :TestCaseRun, :TriggerEvent, :User, :Workspace, :BrokenSolutionItem,
            :GitServer, :ResetBrokenSchedules, :SchedulerService, :SolutionManifest, :Xurrent,
            :BillabilityPolicy, :DetectTaskCountDriftJob, :JobRepository, :TaskRecorder,
          ].freeze

          NOT_ALLOWED_NAMES = Set.new(Object.constants
                                    .excluding(:JWT, :URI, :JSON)
                                    .select { |n| n.to_s.upcase == n.to_s } +
                                      [:RUBY_PATCH_LEVEL, :DATA, :ENVx] +
                                      NOT_ALLOWED_CLASS_NAMES)
                                 .freeze

          # Full constant paths that are safe despite their leaf name colliding with a blocked global.
          # The same leaf reached through any other path stays blocked.
          ALLOWED_CONST_PATHS = Set[
            [:IPaaS, :Job, :Outbound, :HTTP].freeze, # our own, used in Xurrent App Connector
            [:IPaaS, :Job].freeze, # our own namespace; the bare Job leaf stays blocked
          ].freeze

          # Whole paths permitted even though their namespace root is blocked. Matched against the
          # outermost constant of the path, so siblings under the same root stay blocked.
          ALLOWED_WHOLE_CONST_PATHS = Set[
            [:ActiveSupport, :SecurityUtils].freeze, # constant-time comparison for signature checks
          ].freeze

          # Nodes that reopen whatever they name. Reopening is not governed by these rules at all,
          # so no allowlist may exempt a constant reached inside one: an exempted path would
          # otherwise be usable to remove or redefine methods on the class for the whole process.
          DEFINITION_NODE_TYPES = [:casgn, :class, :module, :sclass].freeze

          def initialize(...)
            super
            @const_reported = []
            @global_vars_reported = []
            @variables_reported = []
          end

          def on_ivar(node)
            report_variable_access(node.children.first)
          end
          alias on_ivasgn on_ivar
          alias on_cvar on_ivar
          alias on_cvasgn on_ivar

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

          def report_variable_access(name)
            return if @variables_reported.include?(name)

            @variables_reported << name
            on_invalid.call("Access to '#{name}' not allowed.")
          end

          # Reports a blocked constant read; returns the reported name, or nil if allowed.
          def report_const_access(node)
            return unless report_access?(node)

            name = node.children[1]
            on_invalid.call("Access to '#{name}' not allowed.")
            name
          end

          def report_access?(target)
            # Block by constant name regardless of namespace scope. Fail closed: an exemption
            # applies only outside a definition target, so neither allowlist can be used to reopen
            # the class it names.
            name = target.children[1]
            return false if @const_reported.include?(name) || NOT_ALLOWED_NAMES.exclude?(name)

            unless reopened?(target)
              return false if ALLOWED_CONST_PATHS.include?(const_path(target))
              return false if whole_path_allowed?(target)
            end

            @const_reported << name
            true
          end

          # A whole path is permitted only where it receives a method call, which is the position
          # the permitted operation needs. Refusing every other position keeps the value from
          # being bound to a local and reopened there, which no check on this node could see.
          def whole_path_allowed?(target)
            outer = outermost_const(target)
            parent = outer.parent
            return false unless [:send, :csend].include?(parent&.type)
            return false unless parent.children[0].equal?(outer)
            # A constant anywhere above means the call's result is being used as a namespace, so
            # this is the start of a longer path rather than the permitted operation.
            return false if outer.each_ancestor.any?(&:const_type?)

            ALLOWED_WHOLE_CONST_PATHS.include?(const_path(outer))
          end

          # True when the path is being reopened, however the value reaches that point: testing
          # every ancestor rather than climbing a list of known wrappers means a node type nobody
          # enumerated fails closed instead of passing.
          def reopened?(node)
            node.each_ancestor.any? { |ancestor| DEFINITION_NODE_TYPES.include?(ancestor.type) }
          end

          # The last constant node of the path this node belongs to, so an inner namespace is
          # judged by the whole path rather than by the part of it that reached this node. A missing
          # parent leaves the node as its own outermost, which reports rather than exempts.
          def outermost_const(node)
            node = node.parent while node.parent&.const_type? && node.parent.children[0].equal?(node)
            node
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
