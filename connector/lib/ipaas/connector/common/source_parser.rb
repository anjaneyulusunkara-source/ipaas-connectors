require 'ripper'

module IPaaS
  module Connector
    module Common
      # One pass over a source, for the three things a refusal needs to know: the parse tree to
      # measure, the comments to find a data pill in, and the parser's own complaint. Subclassing
      # the builder rather than Ripper keeps the tree `Ripper.sexp` would build.
      class SourceParser < Ripper::SexpBuilderPP
        attr_reader :comments, :diagnostic, :tree

        def self.read(source)
          new(source).read
        end

        def initialize(source)
          super
          @comments = []
        end

        # The builder returns a partial tree for a source it could not parse, so the tree is only
        # published when nothing complained. Ripper raises rather than returning on a source naming
        # an encoding that does not exist, and says so over three lines.
        def read
          sexp = parse
          @tree = sexp if @diagnostic.nil?
          self
        rescue ArgumentError => e
          @diagnostic = e.message.lines.first.strip
          self
        end

        private

        def on_comment(token)
          @comments << token
          super
        end

        # SexpBuilder aliases its error events onto a method of its own, so overriding that one
        # would never be called: name every channel instead. compile_error is the lexer's, which is
        # the only one an unterminated string or heredoc reports through, and the last four are
        # generated as ordinary parser events, so a source reaching one of those publishes a tree
        # and reads as parseable until it is named. Which channel carries a given complaint is not
        # obvious: a duplicated argument name arrives through compile_error, while a parameter that
        # is not a local reaches on_param_error alone.
        def record_error(message)
          return if @diagnostic

          @diagnostic = "line #{lineno}: #{message}"
        end

        def on_parse_error(message, *) = record_error(message)
        def compile_error(message, *) = record_error(message)
        def on_alias_error(message, *) = record_error(message)
        def on_assign_error(message, *) = record_error(message)
        def on_class_name_error(message, *) = record_error(message)
        def on_param_error(message, *) = record_error(message)
      end
    end
  end
end
