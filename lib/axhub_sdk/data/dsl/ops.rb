# frozen_string_literal: true

require_relative 'schema'
require_relative '../errors'

module AxHub
  module Data
    # Predicate DSL: where(col).eq(v), and_(...), or_/not_/raw plus LIKE escaping
    # and ReDoS guards (mirrors node/python dsl/ops).
    #
    # Query expressions are plain symbol-keyed Hashes:
    #   { op: :eq|:ne|:gt|:gte|:lt|:lte|:like, column: "c", value: v }
    #   { op: :in, column: "c", values: [...] }
    #   { op: :and|:or, clauses: [...] }
    #   { op: :not, clause: expr }
    #   { op: :raw, sql: "...", params?: [...] }
    # Only and(eq/ne/gt/gte/lt/lte/in/like) and bare atoms are pushable to the
    # live backend; or/not/raw raise in the where-serializer (mirrors node).
    MAX_LIKE_PATTERN_LENGTH = 1024
    MAX_CONSECUTIVE_WILDCARDS = 4
    MAX_LIKE_ALTERNATION_SEGMENTS = 6

    ESCAPE_LIKE_RE = /[\\%_]/

    module_function

    def escape_like(value)
      return value if value == ''

      value.gsub(ESCAPE_LIKE_RE) { |m| "\\#{m}" }
    end

    # Reject LIKE patterns that translate to catastrophic-backtracking regex
    # shapes (mirrors node assertSafeLikePattern).
    def assert_safe_like_pattern(pattern)
      if pattern.length > MAX_LIKE_PATTERN_LENGTH
        raise ValidationError.new("LIKE pattern exceeds #{MAX_LIKE_PATTERN_LENGTH} chars; refuse to compile", 'like_pattern_too_long')
      end

      run_of_wildcards = 0
      segments = 0
      i = 0
      n = pattern.length
      while i < n
        ch = pattern[i]
        if ch == '\\'
          i += 2
          run_of_wildcards = 0
          next
        end
        if ch == '%'
          run_of_wildcards += 1
          if run_of_wildcards >= MAX_CONSECUTIVE_WILDCARDS
            raise ValidationError.new("LIKE pattern has #{run_of_wildcards} consecutive '%'; refuse to compile (ReDoS guard)", 'like_pattern_redos')
          end
        else
          segments += 1 if run_of_wildcards == 1
          run_of_wildcards = 0
        end
        i += 1
      end
      if segments > MAX_LIKE_ALTERNATION_SEGMENTS
        raise ValidationError.new("LIKE pattern has #{segments} '%X%' alternation segments; refuse to compile (ReDoS guard)", 'like_pattern_redos')
      end
    end

    def raw(sql, params = nil)
      params.nil? ? { op: :raw, sql: sql } : { op: :raw, sql: sql, params: params }
    end

    def and_(*clauses)
      { op: :and, clauses: clauses }
    end

    def or_(*clauses)
      { op: :or, clauses: clauses }
    end

    def not_(clause)
      { op: :not, clause: clause }
    end

    # Start a predicate for a column. Accepts a DataColumn, a String, or a Symbol.
    #
    #   where(:status).eq("paid")
    #   where("status").eq("paid")
    #   where(schema.cols["status"]).eq("paid")
    #
    # Block form (idiomatic Ruby): yields the builder and returns its result, so
    # the bare-atom expr can be written without a trailing chain.
    #
    #   where(:status) { |c| c.eq("paid") }
    def where(column)
      name = column.is_a?(DataColumn) ? column.name : column.to_s
      builder = WhereBuilder.new(name)
      return yield(builder) if block_given?

      builder
    end

    class LikeBuilder
      def initialize(name)
        @name = name
      end

      def contains(value)
        { op: :like, column: @name, value: "%#{Data.escape_like(value)}%" }
      end

      def starts_with(value)
        { op: :like, column: @name, value: "#{Data.escape_like(value)}%" }
      end

      def ends_with(value)
        { op: :like, column: @name, value: "%#{Data.escape_like(value)}" }
      end

      def raw(value)
        Data.assert_safe_like_pattern(value)
        { op: :like, column: @name, value: value }
      end
    end

    class WhereBuilder
      attr_reader :like

      def initialize(name)
        @name = name
        @like = LikeBuilder.new(name)
      end

      def eq(value)  = _binary(:eq, value)
      def ne(value)  = _binary(:ne, value)
      def gt(value)  = _binary(:gt, value)
      def gte(value) = _binary(:gte, value)
      def lt(value)  = _binary(:lt, value)
      def lte(value) = _binary(:lte, value)

      def in_(values)
        { op: :in, column: @name, values: values.to_a }
      end

      private

      def _binary(op, value)
        { op: op, column: @name, value: value }
      end
    end
  end
end
