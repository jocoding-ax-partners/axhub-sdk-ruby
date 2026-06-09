# frozen_string_literal: true

require 'uri'
require_relative 'dsl/schema'
require_relative 'errors'

module AxHub
  module Data
    # Runtime schema introspection, with appId-resolution PRIMARY and the slug
    # /inspect endpoint as a best-effort fallback, plus error normalization
    # (mirrors node/python discover).
    #
    # Primary:  GET /api/v1/apps?tenant_slug=... -> GET /api/v1/apps/{appId}/tables/{table}
    # Fallback: GET /api/v1/tenants/{t}/apps/{a}/tables/{table}/inspect
    # Neither endpoint has a generated operation-id, so discover goes through the
    # raw-path transport. camelize: true here so table_name/tableName both resolve
    # (inspect payload is metadata, not user row data).
    APP_LOOKUP_PAGE_SIZE = 100
    APP_LOOKUP_MAX_PAGES = 10
    APP_LOOKUP_BUDGET_MS = 5_000

    FORBIDDEN_COLUMN_NAMES = %w[__proto__ constructor prototype].freeze
    COLUMN_NAME_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    module_function

    def _encode(value)
      URI.encode_www_form_component(value.to_s)
    end

    def fetch_discovered_schema(client, tenant_slug, app_slug, table, fresh: nil, ttl_ms: nil)
      # The appId path is the route the `axhub` CLI uses and is verified to work
      # with a data-ring PAT (2026-06). The slug `/inspect` route rejects a slug
      # in the {tenant} path segment on the live backend ("tenant_id 형식이 잘못됐어요",
      # HTTP 400) — a 400 not a 404, so the old slug-first order never reached the
      # working path. appId is primary; slug inspect is a best-effort fallback. The
      # appId error is the meaningful one, so it is what surfaces.
      begin
        _fetch_app_id_inspect(client, tenant_slug, app_slug, table)
      rescue StandardError => err
        begin
          _fetch_slug_inspect(client, tenant_slug, app_slug, table)
        rescue StandardError
          raise _normalize_discover_error(err, table)
        end
      end
    end

    def _fetch_slug_inspect(client, tenant_slug, app_slug, table)
      path = "/api/v1/tenants/#{_encode(tenant_slug)}/apps/#{_encode(app_slug)}/tables/#{_encode(table)}/inspect"
      raw = client.request_raw('GET', path, camelize: true)
      schema_from_inspect_result(table, raw)
    end

    def _fetch_app_id_inspect(client, tenant_slug, app_slug, table)
      app_id = _resolve_app_id(client, tenant_slug, app_slug)
      raise TableNotFoundError.new("Dynamic data table '#{table}' was not found") if app_id.nil? || app_id.empty?

      path = "/api/v1/apps/#{_encode(app_id)}/tables/#{_encode(table)}"
      raw = client.request_raw('GET', path, camelize: true)
      schema_from_inspect_result(table, raw)
    end

    def _resolve_app_id(client, tenant_slug, app_slug)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      cursor = nil
      APP_LOOKUP_MAX_PAGES.times do |page|
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0 - started_at > APP_LOOKUP_BUDGET_MS
          raise IntrospectFailedError.new(
            "app lookup budget exceeded (#{APP_LOOKUP_BUDGET_MS}ms) while searching for slug '#{app_slug}' in tenant '#{tenant_slug}'"
          )
        end
        query = { 'tenant_slug' => tenant_slug, 'limit' => APP_LOOKUP_PAGE_SIZE }
        query['cursor'] = cursor if cursor
        raw = client.request_raw('GET', '/api/v1/apps', query: query, camelize: true)
        raw ||= {}
        items = raw['items'] || []
        match = items.find { |app| app['slug'] == app_slug && app['id'].is_a?(String) }
        return match['id'] if match && match['id']

        # Empty page on the first request means the tenant truly has no apps.
        return nil if page.zero? && items.empty?

        next_cursor = raw['next_cursor'] || raw['nextCursor']
        return nil if next_cursor.nil? || next_cursor == ''

        cursor = next_cursor
      end
      raise ScanLimitExceededError.new(
        "App lookup exceeded #{APP_LOOKUP_MAX_PAGES} pages x #{APP_LOOKUP_PAGE_SIZE} apps without finding slug '#{app_slug}'"
      )
    end

    def _normalize_discover_error(err, table)
      return err if err.is_a?(TableNotFoundError) || err.is_a?(IntrospectFailedError) || err.is_a?(ScanLimitExceededError)

      if _not_found?(err)
        return TableNotFoundError.new(
          "Dynamic data table '#{table}' was not found",
          request_id: (err.respond_to?(:request_id) ? err.request_id : nil)
        )
      end
      status = err.respond_to?(:status) ? err.status : nil
      if status.is_a?(Integer) && status >= 500
        return IntrospectFailedError.new(
          "Failed to introspect dynamic data table '#{table}'",
          status: status,
          retryable: (err.respond_to?(:retryable) ? !!err.retryable : false),
          request_id: (err.respond_to?(:request_id) ? err.request_id : nil)
        )
      end
      err
    end

    def schema_from_inspect_result(table, raw)
      raw ||= {}
      columns = raw['columns'] || []
      shape = {}
      columns.each do |column|
        name = column['name']
        next if FORBIDDEN_COLUMN_NAMES.include?(name)
        next unless name.is_a?(String) && COLUMN_NAME_RE.match?(name)

        shape[name] = _column_type_to_def(column['type'])
      end
      table_name = raw['tableName'] || raw['table_name'] || raw['name'] || table
      Data.define_schema({ 'table' => table_name, 'columns' => shape })
    end

    def _column_type_to_def(col_type)
      case col_type
      when 'uuid' then 'uuid'
      when 'int', 'integer', 'bigint' then 'integer'
      when 'float', 'numeric', 'double precision', 'real' then 'number'
      when 'bool', 'boolean' then 'boolean'
      when 'timestamp', 'timestamptz', 'timestamp with time zone' then 'timestamp'
      when 'json', 'jsonb' then 'json'
      else 'string' # text / varchar / character varying / unknown -> string
      end
    end

    def _not_found?(err)
      return true if err.is_a?(TableNotFoundError)

      err.is_a?(AxHub::Error) && err.respond_to?(:status) && err.status == 404
    end
  end
end
