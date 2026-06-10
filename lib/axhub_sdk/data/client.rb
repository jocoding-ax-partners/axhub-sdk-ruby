# frozen_string_literal: true

require 'uri'
require_relative 'dsl/schema'
require_relative 'dsl/validation'
require_relative 'errors'
require_relative 'pagination'
require_relative 'projection'
require_relative 'schema_cache'
require_relative 'where_serializer'
require_relative 'discover'

module AxHub
  module Data
    # Ergonomic data layer: fluent builder + dynamic-table CRUD + offset
    # pagination (mirrors node index.ts DataClient / TenantDataFactory /
    # AppDataFactory / DataTableClient).
    #
    # Wire paths (EXACTLY as node, via the raw-path transport so row bodies and
    # the list envelope are returned verbatim, no snake->camel rewriting):
    #   list / insert         GET|POST          /data/{tenant}/{app}/{table}
    #   get / update / delete  GET|PATCH|DELETE  /data/{tenant}/{app}/{table}/{id}
    #   count                 GET               /data/{tenant}/{app}/{table}/_count
    module_function

    def _encode(value)
      URI.encode_www_form_component(value.to_s)
    end

    def _clamp_per_page(value)
      return nil if value.nil?
      return 100 unless value.is_a?(Numeric) && value.finite?

      [100, [1, value.to_i].max].min
    end

    def _reject_legacy_page_options(after, before, direction, _table_name)
      return if after.nil? && before.nil? && direction.nil?

      raise LegacyCursorError.new(
        'after/before keyset cursors are not supported by the live AX Hub data API; use cursor/page numeric offset pagination'
      )
    end

    def _validate_plain_cursor(cursor, _table_name)
      if cursor.length > MAX_CURSOR_TOKEN_LENGTH
        raise InvalidCursorError.new("Cursor token exceeds maximum size (#{MAX_CURSOR_TOKEN_LENGTH} chars)")
      end
      if cursor.start_with?('v1:')
        raise LegacyCursorError.new(
          'Legacy v1: cursor token is not compatible with AX Hub offset-only pagination; restart pagination without cursor'
        )
      end
      if Data.is_v2_cursor(cursor)
        raise LegacyCursorError.new(
          'v2 keyset cursors are not supported by the live AX Hub data API; restart pagination and use the numeric cursor returned by list()'
        )
      end
      unless cursor.match?(/\A-?\d+\z/)
        raise InvalidCursorError.new('Plain cursor must be a positive integer page or a v2: keyset token')
      end
      parsed = cursor.to_i
      raise InvalidCursorError.new('Plain cursor must be a positive integer page or a v2: keyset token') if parsed < 1
    end

    def _resolve_offset_page(cursor, page, table_name)
      unless cursor.nil?
        _validate_plain_cursor(cursor, table_name)
        return cursor.to_i
      end
      return 1 if page.nil?
      raise InvalidCursorError.new('page must be a positive integer') unless page.is_a?(Integer) && page >= 1

      page
    end
  end

  module Data
    # Client bound to one {tenant}/{app}/{table} with CRUD + pagination.
    class DataTableClient
      attr_reader :schema

      def initialize(client, tenant_slug, app_slug, table_name, schema = nil)
        @client = client
        @tenant_slug = tenant_slug
        @app_slug = app_slug
        @table_name = table_name
        @schema = schema
      end

      def list(where: nil, order_by: nil, select: nil, page: nil, page_size: nil, limit: nil, cursor: nil, after: nil, before: nil, direction: nil)
        Data.validate_select_columns(@schema, select)
        Data._reject_legacy_page_options(after, before, direction, @table_name)
        resolved_page = Data._resolve_offset_page(cursor, page, @table_name)
        per_page = Data._clamp_per_page(page_size.nil? ? limit : page_size)
        query = Data.serialize_where(where).dup
        query['per_page'] = per_page unless per_page.nil?
        query['page'] = resolved_page if resolved_page != 1
        sort = Data.serialize_order_by(order_by)
        query['sort'] = sort if sort && sort != ''
        serialized_select = Data.serialize_select(select)
        query['_select'] = serialized_select unless serialized_select.nil?
        raw = Data.map_where_required('list') { @client.request_raw('GET', _path, query: query) } || {}
        items = Data.project_rows(raw['items'] || [], select)
        # mirrors node: current_page falls back to the requested page, has_next
        # reads the backend `has_more` flag verbatim, has_prev derives client-side.
        current_page = raw['page'].nil? ? resolved_page : raw['page']
        has_next = !!(raw['has_more'] || false)
        has_prev = current_page > 1
        PaginatedList.new(
          items: items,
          next_cursor: has_next ? (current_page + 1).to_s : nil,
          first_cursor: has_prev ? (current_page - 1).to_s : nil,
          has_next: has_next,
          has_prev: has_prev,
          total_is_exact: false
        )
      end

      def list_all(where: nil, order_by: nil, select: nil, page_size: nil, limit: nil, &block)
        base = { where: where, order_by: order_by, select: select, limit: limit }
        fetcher = lambda do |p|
          kwargs = base.reject { |_k, v| v.nil? }
          kwargs[:cursor] = p[:cursor] unless p[:cursor].nil?
          ps = p[:page_size].nil? ? page_size : p[:page_size]
          kwargs[:page_size] = ps unless ps.nil?
          list(**kwargs)
        end
        Data.list_all(fetcher, { page_size: page_size }, &block)
      end

      def count(where: nil)
        raw = Data.map_where_required('count') { @client.request_raw('GET', "#{_path}/_count", query: Data.serialize_where(where)) } || {}
        raw['count']
      end

      def get(row_id, select: nil)
        Data.validate_select_columns(@schema, select)
        serialized_select = Data.serialize_select(select)
        query = serialized_select.nil? ? {} : { '_select' => serialized_select }
        row = @client.request_raw('GET', _path(row_id), query: query) || {}
        Data.project_row(row, select)
      end

      def insert(row)
        Data.run_schema_validation(@schema, row, 'insert')
        @client.request_raw('POST', _path, body: row)
      end

      def insert_many(rows)
        rows.each { |row| Data.run_schema_validation(@schema, row, 'insert') }
        # mirrors node: no bulk endpoint exists, so insertMany loops single
        # inserts and returns { items, count }.
        items = rows.map { |row| insert(row) }
        { 'items' => items, 'count' => items.length }
      end

      def update(row_id, patch)
        Data.run_schema_validation(@schema, patch, 'update')
        @client.request_raw('PATCH', _path(row_id), body: patch)
      end

      def delete(row_id)
        @client.request_raw('DELETE', _path(row_id))
        nil
      end

      private

      def _path(row_id = nil)
        base = "/data/#{Data._encode(@tenant_slug)}/#{Data._encode(@app_slug)}/#{Data._encode(@table_name)}"
        row_id.nil? ? base : "#{base}/#{Data._encode(row_id)}"
      end
    end

    class AppDataFactory
      def initialize(data, tenant_slug, app_slug)
        @data = data
        @tenant_slug = tenant_slug
        @app_slug = app_slug
      end

      def table(table)
        @data.table(@tenant_slug, @app_slug, table)
      end

      def discover(table, fresh: nil, ttl_ms: nil)
        @data.discover(@tenant_slug, @app_slug, table, fresh: fresh, ttl_ms: ttl_ms)
      end

      def invalidate_schema(table = nil)
        if table.nil?
          @data.invalidate_schema
        else
          @data.invalidate_schema(@tenant_slug, @app_slug, table)
        end
      end
    end

    class TenantDataFactory
      def initialize(data, tenant_slug)
        @data = data
        @tenant_slug = tenant_slug
      end

      def app(app_slug)
        AppDataFactory.new(@data, @tenant_slug, app_slug)
      end
    end

    # Entry point for the ergonomic data layer; holds the per-client schema cache
    # used by discover() (mirrors node DataClient).
    class DataClient
      def initialize(client, schema_cache: nil)
        @client = client
        @schema_cache = case schema_cache
                        when SchemaCache then schema_cache
                        when Hash then SchemaCache.new(**schema_cache.transform_keys(&:to_sym))
                        else SchemaCache.new
                        end
      end

      def table(tenant_slug, app_slug, table)
        schema = table.is_a?(DataTableSchema) ? table : nil
        table_name = table.is_a?(DataTableSchema) ? table.table : table
        DataTableClient.new(@client, tenant_slug, app_slug, table_name, schema)
      end

      def scoped(tenant_slug)
        TenantDataFactory.new(self, tenant_slug)
      end

      def discover(tenant_slug, app_slug, table, fresh: nil, ttl_ms: nil)
        key = Data.schema_cache_key(tenant_slug, app_slug, table)
        schema = @schema_cache.get_or_set(key, fresh: fresh, ttl_ms: ttl_ms) do
          Data.fetch_discovered_schema(@client, tenant_slug, app_slug, table, fresh: fresh, ttl_ms: ttl_ms)
        end
        DataTableClient.new(@client, tenant_slug, app_slug, schema.table, schema)
      end

      def invalidate_schema(tenant_slug = nil, app_slug = nil, table = nil)
        if !tenant_slug.nil? && !app_slug.nil? && !table.nil?
          @schema_cache.invalidate(Data.schema_cache_key(tenant_slug, app_slug, table))
          return
        end
        @schema_cache.invalidate
      end
    end
  end
end
