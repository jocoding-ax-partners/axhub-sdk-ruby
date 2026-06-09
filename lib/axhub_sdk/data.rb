# frozen_string_literal: true

# Ergonomic data layer for the AX Hub Ruby SDK.
#
# Public surface (mirrors the node `resources/data` layer):
#
#   client.tenant(tenant_slug).app(app_slug).data.table(name_or_schema)
#   client.tenant(tenant_slug).app(app_slug).data.discover(table)
#
# returns a DataTableClient with list / list_all / count / get / insert /
# insert_many / update / delete, plus the predicate DSL (where(col).eq(v) /
# and_(...) / block form), define_schema(...), and offset-only pagination.
require_relative 'data/errors'
require_relative 'data/dsl/schema'
require_relative 'data/dsl/ops'
require_relative 'data/dsl/validation'
require_relative 'data/pagination'
require_relative 'data/projection'
require_relative 'data/where_serializer'
require_relative 'data/schema_cache'
require_relative 'data/discover'
require_relative 'data/client'

module AxHub
  module Data
    # Fluent scope wrappers so the public chain reads `client.tenant(t).app(a).data`
    # (mirrors node/python, where `.data` on the app scope yields the ergonomic
    # AppDataFactory). `client.data` itself stays the operation-id OperationClient.
    class AppScope
      attr_reader :data

      def initialize(ergo_data, tenant_slug, app_slug)
        # `ergo_data` is the single per-client DataClient (memoized on Client), so
        # its schema cache persists across every tenant().app() chain — node parity.
        @data = ergo_data.scoped(tenant_slug).app(app_slug)
      end
    end

    class TenantScope
      def initialize(ergo_data, tenant_slug)
        @ergo_data = ergo_data
        @tenant_slug = tenant_slug
      end

      def app(app_slug)
        AppScope.new(@ergo_data, @tenant_slug, app_slug)
      end
    end
  end

  # --- Ergonomic data layer fluent surface (mirrors node client.tenant().app().data) ---
  # `client.data` stays the operation-id route-table OperationClient (the
  # conformance vectors + e2e tests depend on it). The ergonomic data layer is
  # reached only through the tenant/app fluent chain, exactly as in node/python.
  class Client
    # The single per-client ergonomic DataClient, lazily memoized so the schema
    # cache (TTL/negative-TTL/LRU) survives across tenant().app() chains (mirrors
    # node, where `data` is one per-SDK DataClient).
    def ergo_data
      @ergo_data ||= AxHub::Data::DataClient.new(self, schema_cache: @schema_cache_opt)
    end

    def tenant(tenant_slug)
      AxHub::Data::TenantScope.new(ergo_data, tenant_slug)
    end
  end
end
