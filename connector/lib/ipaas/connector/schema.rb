module IPaaS
  module Connector
    class Schema
      extend IPaaS::Connector::Common::ProcRules::ProcSafe

      proc_safe :includes, :after_update

      include IPaaS::Connector::Common::Model

      attr_accessor :connector, :reference, :shared
      attribute :name, length: { in: 2..120 }

      schema_fields

      function :after_update

      delegate :trigger, :action, :connection, :config, :input,
               :helpers, :cache_read, :cache_write, :cache_clear,
               to: :context_or_connector, allow_nil: true

      def initialize(reference, &block)
        self.reference = reference
        self.instance_eval(&block) if block
      end

      def example
        fields.filter_map do |field|
          next unless field.is_a?(Field)

          [field.id, field.example]
        end.to_h
      end

      def resolve(context, field_mapping, &block)
        # A schema marked shared is a process-global singleton (RecurrenceType): its after_update
        # mutates fields in place and validation reads those flags live, so concurrent requests
        # would contaminate each other. Resolve on a private copy to keep the template read-only.
        # #80388755.
        return deep_dup.tap { |copy| copy.shared = false }.resolve(context, field_mapping, &block) if shared?

        using_context(context) { resolve_within_context(context, field_mapping, &block) }
      end

      def shared?
        @shared == true
      end

      # explicitly regenerate the schema itself, e.g. when the trigger configuration is updated
      def regenerate(context, &block)
        using_context(context) do
          @regenerator ||= block
          if context && @regenerator
            IPaaS::Connector::Mapping::ResolvedMapping.tracking_resolution(context) do
              context.instance_exec(self, &@regenerator)
            end
          end
          nil # explicit nil as to not inadvertently return move these fields to a different schema
        end
      end

      def inspect
        inspected_name = name.present? ? " '#{name}'" : ''
        "Schema#{inspected_name} (#{reference}) - #{fields.map(&:id)}"
      end

      def deep_dup
        super.tap do |duped|
          duped.attributes = attributes.deep_dup
          duped.connector = connector
        end
      end

      def includes(mixin)
        unless mixin.respond_to?(:apply_schema)
          raise IPaaS::Error, "Schema extension #{mixin.name} must include IPaaS::Connector::Schema::Extension."
        end

        mixin.apply_schema(self)
      end

      def field_definition(field_id)
        fields.detect { |f| f.id.to_s == field_id.to_s }
      end

      def declares_secret_string?
        Array(fields).any? { |field| field.is_a?(Field) && field.declares_secret_string? }
      end

      private

      def resolve_within_context(context, field_mapping, &block)
        was_resolving = @resolving
        @resolving = true
        begin
          values = resolved_mapping(context, field_mapping)
          safe_resolve(context, field_mapping, values, was_resolving, &block)
        ensure
          @resolving = was_resolving
        end
      end

      def update_values_after_update(context, field_mapping, values)
        return values unless after_update

        using_context(context) do
          # TODO: How to properly handle this error? It is most likely an issue in the connector itself
          on_invalid = ->(msg) { raise("Schema '#{reference}' after_update failure: #{msg}") }
          proc_helper = IPaaS::Connector::Common::ProcHelper.new(context, after_update, on_invalid: on_invalid)
          new_fields = IPaaS::Connector::Mapping::ResolvedMapping.tracking_resolution(context) do
            proc_helper.execute(self.fields, values)
          end
          self.fields = new_fields if new_fields.is_a?(Array) && new_fields.all?(Field)

          # resolve again, fields may be updated
          resolved_mapping(context, field_mapping).resolve
        end
      end

      def resolved_mapping(context, field_mapping)
        IPaaS::Connector::Mapping::ResolvedMapping.new(context, self.fields, field_mapping)
      end

      def safe_resolve(context, field_mapping, values, was_resolving)
        begin
          values.resolve
          yield values if block_given?
          values = update_values_after_update(context, field_mapping, values) unless was_resolving
          yield values if block_given?
        rescue StandardError, SystemStackError => e
          values.base_error = e
        end
        values
      end

      def using_context(context)
        return yield if context == @context

        @context = context
        begin
          yield
        ensure
          @context = nil
        end
      end

      def context_or_connector
        @context || connector
      end
    end
  end
end
