# frozen_string_literal: true

module AxHub
  module Data
    # Schema definitions and define_schema (mirrors node/python dsl/schema).
    #
    # Column defs are either a primitive type string ("uuid" | "string" |
    # "number" | "integer" | "boolean" | "timestamp" | "json") or an enum
    # descriptor { type: "enum", values: [...] }. define_schema builds the `cols`
    # accessor map used by the where(schema.cols["x"]) typed DSL path.
    DataColumn = Struct.new(:table, :name, :definition) do
      def initialize(table:, name:, definition:)
        super(table, name, definition)
      end
    end

    class DataTableSchema
      attr_reader :table, :columns, :cols, :validate

      def initialize(table:, columns:, cols:, validate: nil)
        @table = table
        @columns = columns
        @cols = cols
        @validate = validate
        freeze
      end
    end

    module_function

    # Define a data table schema. Two call shapes mirror node's two overloads:
    #   define_schema("orders", { "id" => "uuid", "total" => "number" })
    #   define_schema({ "table" => "orders", "columns" => {...} }, validate: ...)
    # An existing DataTableSchema is re-wrapped, optionally attaching `validate`.
    def define_schema(table_or_input, columns = nil, validate: nil)
      if table_or_input.is_a?(DataTableSchema)
        return DataTableSchema.new(
          table: table_or_input.table,
          columns: table_or_input.columns,
          cols: table_or_input.cols,
          validate: validate.nil? ? table_or_input.validate : validate
        )
      end

      if table_or_input.is_a?(Hash)
        h = _stringify_keys(table_or_input)
        table = h['table']
        shape = _stringify_keys(h['columns'])
      else
        table = table_or_input
        raise ArgumentError, 'define_schema requires columns when called with a table name' if columns.nil?

        shape = _stringify_keys(columns)
      end

      cols = shape.each_with_object({}) do |(name, definition), acc|
        acc[name] = DataColumn.new(table: table, name: name, definition: definition)
      end
      DataTableSchema.new(table: table, columns: shape, cols: cols, validate: validate)
    end

    def _stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
  end
end
