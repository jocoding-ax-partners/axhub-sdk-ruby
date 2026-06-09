# frozen_string_literal: true

require 'json'
require 'date'
require_relative 'errors'

module AxHub
  module Data
    # Serialize the predicate DSL into backend filter query params (mirrors node
    # where-serializer + python where_serializer).
    #
    # Each pushable atom becomes column=<op>.<value> (PostgREST-style). Repeated
    # columns collapse into an array so the transport emits repeated query params
    # (URI.encode_www_form repeats array-valued keys). Only top-level and(...) of
    # pushable atoms and bare atoms are accepted; or/not/raw and nested-and raise
    # ValidationError — this matches the live backend's filter grammar.
    PUSHABLE_BINARY = %i[eq ne gt gte lt lte like].freeze

    module_function

    def serialize_where(expr)
      return {} if expr.nil?

      out = {}
      _collect_pushable_filters(expr, allow_and: true).each do |f|
        _append_query(out, f[:column], f[:value])
      end
      out
    end

    def _append_query(out, key, value)
      if !out.key?(key)
        out[key] = value
      elsif out[key].is_a?(Array)
        out[key] << value
      else
        out[key] = [out[key], value]
      end
    end

    def _collect_pushable_filters(expr, allow_and:)
      op = expr[:op]
      if PUSHABLE_BINARY.include?(op)
        return [{ column: expr[:column], value: "#{op}.#{_stringify(expr[:value])}" }]
      end

      if op == :in
        values = expr[:values].map { |v| _stringify(v) }
        bad = values.find { |v| v.include?(',') }
        unless bad.nil?
          raise ValidationError.new(
            "IN filter values cannot contain commas because the live backend uses comma-separated IN lists (bad value: #{bad})",
            'filter_in_comma'
          )
        end
        return [{ column: expr[:column], value: "in.#{values.join(',')}" }]
      end

      if op == :and && allow_and
        out = []
        expr[:clauses].each { |clause| out.concat(_collect_pushable_filters(clause, allow_and: false)) }
        return out
      end

      # or / not / raw / nested-and all fall through to the rejection below.
      raise ValidationError.new(
        "Data where clause '#{op}' cannot be pushed to the live backend; use top-level and(eq/ne/gt/gte/lt/lte/in/like) only",
        'unsupported_filter'
      )
    end

    def _stringify(value)
      case value
      when Time then value.iso8601
      when DateTime, Date then value.iso8601
      when nil then 'null'
      when true then 'true'
      when false then 'false'
      when String, Integer, Float then value.to_s
      else JSON.generate(value)
      end
    end
  end
end
