module IPaaS
  module Connector
    module Common
      # The size and nesting depth a solution YAML file may have: properties of the file as
      # written, so they decide the same way everywhere — unlike the parser's call stack.
      class YamlLimits
        # Chosen ceilings rather than anything the parser imposes.
        MAX_BYTES = 2048.kilobytes
        MAX_DEPTH = 250

        HALT = :yaml_limits_halt
        private_constant :HALT

        class Exceeded < IPaaS::Error
          attr_reader :kind

          def initialize(kind)
            @kind = kind
            message = case kind
                      when :size then "exceeds the maximum size of #{MAX_BYTES / 1.kilobyte} KB"
                      when :depth then "exceeds the maximum nesting depth of #{MAX_DEPTH}"
                      else kind
                      end
            super(message)
          end
          # not frozen on purpose, we extend it to add additional information later
        end

        # Counts nesting off the event stream, so a file that would overflow the load stays
        # measurable. First document only: that is the only one the read path loads.
        class DepthHandler < Psych::Handler
          attr_reader :max

          def initialize(limit)
            super()
            @limit = limit
            @depth = 0
            @max = 0
          end

          def start_mapping(_anchor, _tag, _implicit, _style) = enter
          def start_sequence(_anchor, _tag, _implicit, _style) = enter
          def end_mapping = leave
          def end_sequence = leave
          def end_document(_implicit) = throw(HALT)

          private

          def enter
            @depth += 1
            @max = @depth if @depth > @max
            throw(HALT) if @limit && @depth > @limit
          end

          def leave
            @depth -= 1
          end

          # Frozen with the class it serves: a neutered event method would silently report no depth.
          freeze
        end

        class << self
          # Size is judged first: it costs no parse, so content over it is never measured for
          # depth. Unparseable content raises, as `depth` does.
          def exceeded(content)
            return :size if bytes(content) > MAX_BYTES
            return :depth if depth(content, limit: MAX_DEPTH) > MAX_DEPTH

            nil
          end

          def apply!(content)
            breach = exceeded(content)
            raise Exceeded, breach if breach
          end

          # Paired with `depth`: one place for both measurements, and a seam a sweep can prove.
          def bytes(content)
            content.bytesize
          end

          # The depth of the file as written, which is also the depth a load would build: both
          # load paths refuse aliases, so no anchor can stand for a subtree deeper than it looks.
          def depth(content, limit: nil)
            handler = DepthHandler.new(limit)
            catch(HALT) { Psych::Parser.new(handler).parse(content) }
            handler.max
          end
        end

        # Prevent changing the definition of this class, which could be a silent bypass.
        freeze
      end
    end
  end
end
