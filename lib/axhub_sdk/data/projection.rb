# frozen_string_literal: true

require_relative 'errors'

module AxHub
  module Data
    # Column projection: `select` serialization, validation, and client-side row
    # narrowing (mirrors node/python projection).
    #
    # serialize_select joins columns with commas into the `_select` query param.
    # validate_select_columns rejects an empty select and, when a schema is known,
    # unknown columns. project_row/project_rows narrow returned rows to the
    # selected keys client-side. Rows are string-keyed (camelize-off transport).
    module_function

    def serialize_select(select)
      return nil if select.nil?

      select.join(',')
    end

    def validate_select_columns(schema, select)
      return if select.nil?

      if select.length.zero?
        raise ValidationError.new('select must include at least one column; omit select to fetch full rows', 'select_empty')
      end
      return if schema.nil?

      allowed = schema.columns.keys
      invalid = select.reject { |c| allowed.include?(c) }
      return if invalid.empty?

      plural = invalid.length == 1 ? '' : 's'
      raise ValidationError.new("select contains unknown column#{plural}: #{invalid.join(', ')}", 'select_unknown_column')
    end

    def project_row(row, select)
      return row.dup if select.nil?

      select.each_with_object({}) { |k, acc| acc[k] = row[k] if row.key?(k) }
    end

    def project_rows(rows, select)
      return rows.map(&:dup) if select.nil?

      rows.map { |r| project_row(r, select) }
    end
  end
end
