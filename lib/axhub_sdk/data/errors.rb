# frozen_string_literal: true

module AxHub
  module Data
    # Typed data-layer errors. These subclass the existing single AxHub::Error so
    # the (category, code) contract that the conformance vectors + error tests
    # match on keeps working, while callers can still rescue the specific failure
    # (mirrors node/python LegacyCursorError / InvalidCursorError / ValidationError
    # / TableNotFoundError / IntrospectFailedError / ScanLimitExceededError).
    class ValidationError < AxHub::Error
      def initialize(message, code = 'validation', status: 0, retryable: false, request_id: nil)
        super(category: 'validation', code: code, message: message, status: status, retryable: retryable, request_id: request_id)
      end
    end

    # Raised when an after/before keyset or v1:/v2: cursor token is supplied; the
    # live AX Hub data API is offset-only (mirrors node LegacyCursorError).
    class LegacyCursorError < AxHub::Error
      def initialize(message, request_id: nil)
        super(category: 'validation', code: 'legacy_cursor', message: message, status: 0, retryable: false, request_id: request_id)
      end
    end

    class InvalidCursorError < AxHub::Error
      def initialize(message, request_id: nil)
        super(category: 'validation', code: 'invalid_cursor', message: message, status: 0, retryable: false, request_id: request_id)
      end
    end

    class TableNotFoundError < AxHub::Error
      def initialize(message, request_id: nil)
        super(category: 'not_found', code: 'table_not_found', message: message, status: 404, retryable: false, request_id: request_id)
      end
    end

    class IntrospectFailedError < AxHub::Error
      def initialize(message, status: 0, retryable: false, request_id: nil)
        super(category: 'internal', code: 'introspect_failed', message: message, status: status, retryable: retryable, request_id: request_id)
      end
    end

    class ScanLimitExceededError < AxHub::Error
      def initialize(message, request_id: nil)
        super(category: 'internal', code: 'scan_limit_exceeded', message: message, status: 0, retryable: false, request_id: request_id)
      end
    end
    # The backend 400s an unfiltered list/count on NON-owner-scoped tables
    # ("최소 1개의 WHERE 필터가 필요해요") but ACCEPTS it on owner-scoped tables
    # (rows auto-scope to the caller) — both confirmed live 2026-06. A client
    # pre-check cannot tell them apart (0.3.0 regression), so the request goes
    # through and only the backend 400 is normalized.
    def self.map_where_required(op)
      yield
    rescue StandardError => e
      code = e.respond_to?(:code) ? e.code : nil
      status = e.respond_to?(:status) ? e.status : nil
      if code.to_s == 'required' && status.to_i == 400
        raise ValidationError.new(
          "AxHub data #{op} requires at least one WHERE filter on this table " \
          '(the backend rejects unfiltered scans on non-owner-scoped tables). Pass `where:`.',
          'where_required'
        )
      end
      raise
    end

  end
end
