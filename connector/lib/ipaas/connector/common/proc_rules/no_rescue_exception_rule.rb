module IPaaS
  module Connector
    module Common
      module ProcRules
        # Exceptions must be able to propagate out of authored procs: runtimes that execute
        # them enforce wall-clock deadlines by interrupting the proc with a non-StandardError
        # exception. A rescue clause that captures one — directly, via an ancestor every
        # object shares (Object, Kernel, BasicObject), or via a non-literal class the
        # validator cannot see through — lets a proc swallow the deadline and spin unbounded
        # or return a wrong value. An `ensure` body runs after the deadline already fired,
        # i.e. with no timer left to bound it.
        class NoRescueExceptionRule < ProcRule
          # Matched by leaf name regardless of scope; fail closed like NoGlobalAccessRule.
          BLOCKED_CLASS_NAMES = Set[
            # ancestors every exception shares, so rescuing one captures any interrupt
            :Exception, :Object, :BasicObject, :Kernel,
            # VM-level exceptions no proc has business handling
            :SystemExit, :SignalException, :Interrupt,
            :NoMemoryError, :SystemStackError, :SecurityError, :ScriptError,
            # deadline classes runtimes raise to interrupt an overrunning proc
            :DeadlineExceeded, :ConfigTesterTimeout,
            :MaxActionTimeExceededError, :MaxTriggerProcessingTimeExceededError,
            :RequestTimeoutException, :RequestTimeoutError,
          ].freeze

          def initialize(...)
            super
            @reported = []
          end

          def on_resbody(node)
            exception_classes, _assignment, _body = *node
            return if exception_classes.nil? # bare `rescue` catches StandardError only

            exception_classes.children.each { |entry| validate_rescued_class(entry) }
          end

          def on_ensure(_node)
            report("'ensure' is not allowed.")
          end

          private

          def validate_rescued_class(entry)
            unless entry.type == :const
              report("'rescue' requires literal error classes, e.g. 'rescue StandardError'.")
              return
            end

            name = entry.children[1]
            report("'rescue #{name}' is not allowed; rescue StandardError or a specific error class.") if
              BLOCKED_CLASS_NAMES.include?(name)
          end

          def report(message)
            return if @reported.include?(message)

            @reported << message
            on_invalid.call(message)
          end
        end
      end
    end
  end
end
