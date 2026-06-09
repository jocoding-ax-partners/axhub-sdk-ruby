# frozen_string_literal: true

require_relative 'dsl/schema'

module AxHub
  module Data
    # Per-client schema cache for runtime data.discover (mirrors node/python
    # schema-cache).
    #
    # Uses an insertion-ordered Ruby Hash for deterministic LRU eviction
    # (delete+reinsert = move-to-end on read/write, `shift` = evict oldest) and a
    # negative-TTL stale-while-error window: a transient 5xx during refresh keeps
    # the previous entry alive briefly instead of evicting it. The node version
    # de-dupes concurrent in-flight loads; the sync Ruby port omits the in-flight
    # map (no concurrency within a single synchronous call).
    DEFAULT_SCHEMA_CACHE_TTL_MS = 5 * 60_000
    DEFAULT_SCHEMA_CACHE_MAX_ENTRIES = 1000
    DEFAULT_SCHEMA_CACHE_NEGATIVE_TTL_MS = 30_000

    module_function

    def schema_cache_key(tenant_slug, app_slug, table)
      "#{tenant_slug}/#{app_slug}/#{table}"
    end

    class SchemaCache
      Entry = Struct.new(:schema, :expires_at, keyword_init: true)

      def initialize(max_entries: nil, ttl_ms: nil, negative_ttl_ms: nil)
        @store = {}
        @max_entries = [1, max_entries.nil? ? DEFAULT_SCHEMA_CACHE_MAX_ENTRIES : max_entries].max
        @ttl_ms = [1, ttl_ms.nil? ? DEFAULT_SCHEMA_CACHE_TTL_MS : ttl_ms].max
        @negative_ttl_ms = [0, negative_ttl_ms.nil? ? DEFAULT_SCHEMA_CACHE_NEGATIVE_TTL_MS : negative_ttl_ms].max
      end

      def size
        @store.size
      end

      def get(key)
        entry = @store[key]
        return nil if entry.nil?

        if entry.expires_at <= _now_ms
          @store.delete(key)
          return nil
        end
        # refresh recency: move to end (delete + reinsert)
        @store.delete(key)
        @store[key] = entry
        entry.schema
      end

      def set(key, schema, ttl_ms = nil)
        @store.delete(key)
        @store[key] = Entry.new(schema: schema, expires_at: _now_ms + [1, ttl_ms.nil? ? @ttl_ms : ttl_ms].max)
        _evict_overflow
        nil
      end

      def invalidate(key = nil)
        if key.nil?
          @store.clear
        else
          @store.delete(key)
        end
        nil
      end

      def get_or_set(key, fresh: nil, ttl_ms: nil)
        unless fresh
          cached = get(key)
          return cached unless cached.nil?
        end
        previous = @store[key]
        begin
          schema = yield
        rescue StandardError => e
          if !previous.nil? && @negative_ttl_ms.positive? && _transient_server_error?(e)
            @store.delete(key)
            @store[key] = Entry.new(schema: previous.schema, expires_at: _now_ms + @negative_ttl_ms)
          end
          raise
        end
        set(key, schema, ttl_ms)
        schema
      end

      private

      def _now_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      end

      def _transient_server_error?(err)
        status = err.respond_to?(:status) ? err.status : nil
        status.is_a?(Integer) && status >= 500
      end

      def _evict_overflow
        @store.shift while @store.size > @max_entries # oldest first
      end
    end
  end
end
