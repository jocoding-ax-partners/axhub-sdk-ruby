# frozen_string_literal: true

require_relative 'schema'
require_relative '../errors'

module AxHub
  module Data
    # Optional schema validation hook (mirrors node dsl/zod + python validation).
    #
    # The SDK duck-types a zod/dry-validation-style validator so the validation
    # library stays an optional dependency and is never required. A validator is
    # "schema-like" if it responds to `safe_parse` (or `safeParse`). On `update`
    # a `partial` variant is used when available.
    module_function

    def validator_like?(value)
      !value.nil? && (value.respond_to?(:safe_parse) || value.respond_to?(:safeParse))
    end

    def _safe_parse(validator, data)
      validator.respond_to?(:safe_parse) ? validator.safe_parse(data) : validator.safeParse(data)
    end

    # Validate `data` against schema.validate before any network request. `mode`
    # is "insert" or "update" (update uses `partial` when available).
    def run_schema_validation(schema, data, mode)
      validator = schema&.validate
      return if validator.nil?

      unless validator_like?(validator)
        raise AxHub::Error.new(
          category: 'configuration', code: 'validator_missing',
          message: 'define_schema validate option requires a schema-like object with safe_parse'
        )
      end

      effective = validator
      effective = validator.partial if mode == 'update' && validator.respond_to?(:partial)
      result = _safe_parse(effective, data)

      success = _read(result, :success)
      return if success

      error = _read(result, :error)
      issues = _read(error, :issues) || []
      count = issues.empty? ? 1 : issues.length
      raise ValidationError.new("#{count} validation failure#{count == 1 ? '' : 's'} before network request", 'validation_failed')
    end

    # Read an attribute from either a duck-typed object or a Hash.
    def _read(obj, key)
      return nil if obj.nil?
      return obj.public_send(key) if obj.respond_to?(key)
      return obj[key] if obj.is_a?(Hash) && obj.key?(key)
      return obj[key.to_s] if obj.is_a?(Hash) && obj.key?(key.to_s)

      nil
    end
  end
end
