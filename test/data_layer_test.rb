# frozen_string_literal: true

# Unit + wire tests for the ergonomic data layer (mirrors the python
# test_data_layer.py cases). The conformance runner only exercises the
# operation-id route-table surface, not this fluent layer. Covers: fluent
# surface, per_page clamp, offset pagination envelope, legacy/v1/v2/invalid
# cursor rejection, where serialization incl. the IN-comma guard and
# pushable-filter rejection, select validation + projection, LIKE escaping +
# ReDoS guards, CRUD wire paths, list_all drift, discover (appId-first + slug
# fallback + TableNotFound), camelize-off row verbatimness, and schema-cache
# LRU/TTL.
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'json'
require 'socket'
require 'uri'
require 'axhub_sdk'

include AxHub::Data # rubocop:disable Style/MixinUsage — test-local convenience for where/and_/etc.

# ----------------------------- mock data server ------------------------------
# Raw TCPServer (WEBrick is not a default gem on Ruby >= 3.0). Records the last
# request and replies from a shared `response` slot. Serves requests in a loop so
# insert_many / discover (multiple sequential calls) work.
class MockDataServer
  attr_accessor :response
  attr_reader :last, :port

  def initialize
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @response = { status: 200, body: {} }
    @last = {}
    @thread = Thread.new { serve }
  end

  def base_url
    "http://127.0.0.1:#{@port}"
  end

  def reset_last
    @last = {}
  end

  def shutdown
    @running = false
    @server.close
    @thread.kill
  end

  private

  def serve
    @running = true
    loop do
      break unless @running

      conn = begin
        @server.accept
      rescue IOError, Errno::EBADF
        break
      end
      handle(conn)
    end
  end

  def handle(conn)
    request_line = conn.gets
    return conn.close if request_line.nil?

    method, target, = request_line.split(' ')
    headers = {}
    while (line = conn.gets)
      line = line.chomp
      break if line.empty?

      k, v = line.split(': ', 2)
      headers[k.downcase] = v
    end
    length = (headers['content-length'] || '0').to_i
    raw_body = length.positive? ? conn.read(length) : ''
    uri = URI.parse("http://x#{target}")
    @last = {
      'method' => method,
      'path' => uri.path,
      'query' => parse_query(uri.query),
      'raw_query' => uri.query,
      'body' => (raw_body.empty? ? nil : JSON.parse(raw_body)),
      'headers' => headers
    }
    body = JSON.generate(@response[:body].nil? ? {} : @response[:body])
    status = @response[:status] || 200
    conn.write("HTTP/1.1 #{status} OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  ensure
    conn.close
  end

  # parse_qs-equivalent: repeated keys collapse into an array of values.
  def parse_query(query)
    out = {}
    return out if query.nil? || query.empty?

    URI.decode_www_form(query).each do |k, v|
      (out[k] ||= []) << v
    end
    out
  end
end

module ServerCase
  def setup
    @server = MockDataServer.new
    @client = AxHub::Client.new(base_url: @server.base_url, token: 'pat_x', token_type: :pat)
  end

  def teardown
    @server.shutdown
  end

  def table(schema = nil)
    @client.tenant('acme').app('crm').data.table(schema.nil? ? 'orders' : schema)
  end

  def set_response(body, status: 200)
    @server.response = { status: status, body: body }
  end

  def last
    @server.last
  end
end

# ------------------------------- pure units ----------------------------------

class WhereSerializerTest < Minitest::Test
  def test_atom_and_and_and_in
    assert_equal({ 'status' => 'eq.paid' }, serialize_where(where('status').eq('paid')))
    assert_equal(
      { 'total' => 'gte.10', 'status' => 'ne.void' },
      serialize_where(and_(where('total').gte(10), where('status').ne('void')))
    )
    assert_equal({ 'id' => 'in.a,b' }, serialize_where(where('id').in_(%w[a b])))
  end

  def test_bool_and_nil_stringify_like_js
    assert_equal({ 'active' => 'eq.true' }, serialize_where(where('active').eq(true)))
    assert_equal({ 'deleted' => 'eq.null' }, serialize_where(where('deleted').eq(nil)))
  end

  def test_repeated_column_collapses_to_list
    out = serialize_where(and_(where('tag').eq('a'), where('tag').eq('b')))
    assert_equal({ 'tag' => ['eq.a', 'eq.b'] }, out)
  end

  def test_in_comma_guard
    err = assert_raises(ValidationError) { serialize_where(where('name').in_(['a,b'])) }
    assert_equal 'filter_in_comma', err.code
  end

  def test_unsupported_filters_rejected
    [or_(where('a').eq(1)), not_(where('a').eq(1)), { op: :raw, sql: '1=1' }].each do |expr|
      err = assert_raises(ValidationError) { serialize_where(expr) }
      assert_equal 'unsupported_filter', err.code
    end
  end

  def test_nested_and_is_not_pushable
    err = assert_raises(ValidationError) { serialize_where(and_(and_(where('a').eq(1)))) }
    assert_equal 'unsupported_filter', err.code
  end
end

class OrderByTest < Minitest::Test
  def test_string_form_appends_id_tiebreaker
    assert_equal '-total,id', serialize_order_by('-total')
    assert_equal 'name,id', serialize_order_by('name')
  end

  def test_field_list_form
    assert_equal '-total,id', serialize_order_by([{ field: 'total', dir: 'desc' }])
  end

  def test_empty_is_nil
    assert_nil serialize_order_by(nil)
  end
end

class ClampPerPageTest < Minitest::Test
  def test_clamp_1_to_100
    assert_equal 1, AxHub::Data._clamp_per_page(0)
    assert_equal 50, AxHub::Data._clamp_per_page(50)
    assert_equal 100, AxHub::Data._clamp_per_page(1000)
    assert_equal 1, AxHub::Data._clamp_per_page(-5)
    assert_nil AxHub::Data._clamp_per_page(nil)
    assert_equal 100, AxHub::Data._clamp_per_page(Float::INFINITY)
    assert_equal 12, AxHub::Data._clamp_per_page(12.9) # trunc
  end
end

class SelectTest < Minitest::Test
  def test_serialize
    assert_equal 'id,total', serialize_select(%w[id total])
    assert_nil serialize_select(nil)
  end

  def test_empty_select_rejected
    err = assert_raises(ValidationError) { validate_select_columns(nil, []) }
    assert_equal 'select_empty', err.code
  end

  def test_unknown_column_rejected_with_schema
    schema = define_schema('orders', { 'id' => 'uuid', 'total' => 'number' })
    err = assert_raises(ValidationError) { validate_select_columns(schema, %w[id nope]) }
    assert_equal 'select_unknown_column', err.code
  end

  def test_project_row_narrows
    assert_equal({ 'id' => 'x' }, project_row({ 'id' => 'x', 'total' => 5, 'extra' => 1 }, ['id']))
  end
end

class CursorRejectionTest < Minitest::Test
  include ServerCase

  def test_after_before_direction_rejected
    [{ after: 'x' }, { before: 'x' }, { direction: 'forward' }].each do |kw|
      assert_raises(LegacyCursorError) { table.list(**kw) }
    end
  end

  def test_v1_and_v2_cursor_rejected
    assert_raises(LegacyCursorError) { table.list(cursor: 'v1:abc') }
    assert_raises(LegacyCursorError) { table.list(cursor: 'v2:abc') }
  end

  def test_non_integer_cursor_rejected
    assert_raises(InvalidCursorError) { table.list(cursor: 'abc') }
    assert_raises(InvalidCursorError) { table.list(cursor: '0') }
  end

  def test_oversized_cursor_rejected
    assert_raises(InvalidCursorError) { table.list(cursor: '1' * 5000) }
  end

  def test_bad_page_rejected
    # page validation surfaces BEFORE where_required (mirrors node/python order).
    assert_raises(InvalidCursorError) { table.list(page: 0) }
  end

  def test_is_v2_cursor_helper
    assert is_v2_cursor('v2:x')
    refute is_v2_cursor('3')
  end
end

class ListWireTest < Minitest::Test
  include ServerCase

  def test_list_query_and_envelope
    set_response({ 'items' => [{ 'id' => '1', 'created_at' => 't' }], 'page' => 2, 'per_page' => 10, 'has_more' => true })
    result = table.list(
      where: where('status').eq('paid'),
      order_by: '-total',
      select: %w[id created_at],
      page: 2,
      page_size: 10
    )
    assert_equal 'GET', last['method']
    assert_equal '/data/acme/crm/orders', last['path']
    assert_equal ['eq.paid'], last['query']['status']
    assert_equal ['10'], last['query']['per_page']
    assert_equal ['2'], last['query']['page']
    assert_equal ['-total,id'], last['query']['sort']
    assert_equal ['id,created_at'], last['query']['_select']
    assert_equal 'pat_x', last['headers']['x-api-key']
    # envelope mirrors node: next/first cursor are page numbers as strings
    assert_equal '3', result.next_cursor
    assert_equal '1', result.first_cursor
    assert result.has_next
    assert result.has_prev
    refute result.total_is_exact
  end

  def test_row_data_returned_verbatim_no_camelize
    # snake_case keys in row data must NOT be rewritten (mirror node transport).
    set_response({ 'items' => [{ 'id' => '1', 'created_at' => '2020', 'is_active' => true }], 'has_more' => false })
    result = table.list(where: where('id').eq('1'))
    assert_equal({ 'id' => '1', 'created_at' => '2020', 'is_active' => true }, result.items[0])
    assert_nil result.next_cursor
  end

  def test_page_1_omits_page_query
    set_response({ 'items' => [], 'has_more' => false })
    table.list(page: 1, where: where('id').eq('1'))
    refute last['query'].key?('page')
  end

  def test_select_projects_client_side
    set_response({ 'items' => [{ 'id' => '1', 'total' => 9, 'secret' => 'x' }], 'has_more' => false })
    result = table.list(select: %w[id total], where: where('id').eq('1'))
    assert_equal({ 'id' => '1', 'total' => 9 }, result.items[0])
  end

  def test_filterless_list_passes_for_owner_scoped_tables
    # Live contract 2026-06: the backend ACCEPTS unfiltered list/count on
    # owner-scoped tables (rows auto-scope to the caller). The 0.3.0
    # client-side pre-check wrongly blocked this — filterless calls must
    # reach the wire.
    set_response({ 'items' => [{ 'id' => 'mine' }], 'has_more' => false })
    result = table.list
    assert_equal 'mine', result.items[0]['id']
  end

  def test_backend_where_required_400_maps_to_validation_error
    # Non-owner-scoped tables still get the mass-scan guard — server-side.
    # The SDK maps that 400 (code=required) onto the same actionable error.
    set_response(
      { 'error' => { 'message' => '최소 1개의 WHERE 필터가 필요해요', 'code' => 'required',
                     'category' => 'validation', 'retryable' => false,
                     'fields' => [{ 'name' => 'where', 'code' => 'required' }] } },
      status: 400
    )
    err = assert_raises(ValidationError) { table.list }
    assert_equal 'where_required', err.code
    err2 = assert_raises(ValidationError) { table.count }
    assert_equal 'where_required', err2.code
  end
end

class CrudWireTest < Minitest::Test
  include ServerCase

  def test_count
    set_response({ 'count' => 42 })
    n = table.count(where: where('status').eq('paid'))
    assert_equal 42, n
    assert_equal '/data/acme/crm/orders/_count', last['path']
    assert_equal ['eq.paid'], last['query']['status']
  end

  def test_get
    set_response({ 'id' => 'abc', 'total' => 5 })
    row = table.get('abc', select: %w[id total])
    assert_equal({ 'id' => 'abc', 'total' => 5 }, row)
    assert_equal 'GET', last['method']
    assert_equal '/data/acme/crm/orders/abc', last['path']
    assert_equal ['id,total'], last['query']['_select']
  end

  def test_insert
    set_response({ 'id' => 'new', 'total' => 7 })
    out = table.insert({ 'total' => 7 })
    assert_equal({ 'id' => 'new', 'total' => 7 }, out)
    assert_equal 'POST', last['method']
    assert_equal '/data/acme/crm/orders', last['path']
    assert_equal({ 'total' => 7 }, last['body'])
  end

  def test_insert_many_loops
    set_response({ 'id' => 'x' })
    out = table.insert_many([{ 'a' => 1 }, { 'a' => 2 }])
    assert_equal 2, out['count']
    assert_equal 2, out['items'].length
  end

  def test_update
    set_response({ 'id' => 'abc', 'total' => 9 })
    out = table.update('abc', { 'total' => 9 })
    assert_equal 'PATCH', last['method']
    assert_equal '/data/acme/crm/orders/abc', last['path']
    assert_equal({ 'id' => 'abc', 'total' => 9 }, out)
  end

  def test_delete
    set_response({}, status: 204)
    assert_nil table.delete('abc')
    assert_equal 'DELETE', last['method']
    assert_equal '/data/acme/crm/orders/abc', last['path']
  end
end

class ListAllTest < Minitest::Test
  def test_drives_pages_and_emits_drift
    pages = [
      PaginatedList.new(items: [{ 'id' => 1 }], next_cursor: '2', total: 2),
      PaginatedList.new(items: [{ 'id' => 2 }], next_cursor: nil, total: 3) # total grew -> drift
    ]
    i = { n: 0 }
    fetcher = lambda do |_opts|
      page = pages[i[:n]]
      i[:n] += 1
      page
    end
    out = list_all(fetcher).to_a
    kinds = out.map { |x| [x.type, x.type == :item ? x.value : x.added_since] }
    assert_equal([[:item, { 'id' => 1 }], [:drift, 1], [:item, { 'id' => 2 }]], kinds)
  end
end

class DiscoverTest < Minitest::Test
  include ServerCase

  def test_discover_appid_first_then_slug_fallback
    # The mock returns the same inspect payload for every path. appId resolution
    # scans /api/v1/apps (no matching slug -> nil app_id -> TableNotFound), so the
    # flow falls through to the slug /inspect fallback, which succeeds. The LAST
    # observed request is therefore the slug inspect path.
    set_response({
      'tableName' => 'orders',
      'columns' => [
        { 'name' => 'id', 'type' => 'uuid' },
        { 'name' => 'total', 'type' => 'numeric' },
        { 'name' => '__proto__', 'type' => 'text' }, # must be skipped
        { 'name' => 'ok name', 'type' => 'text' } # invalid identifier -> skipped
      ]
    })
    tc = @client.tenant('acme').app('crm').data.discover('orders')
    assert_equal '/api/v1/tenants/acme/apps/crm/tables/orders/inspect', last['path']
    assert_equal({ 'id' => 'uuid', 'total' => 'number' }, tc.schema.columns)
  end

  def test_discover_appid_path_resolves_when_app_found
    # When /api/v1/apps DOES return a matching slug, discover uses the appId path
    # (GET /api/v1/apps/{appId}/tables/{table}) — the verified-working route.
    server2 = AppIdAwareServer.new
    client2 = AxHub::Client.new(base_url: server2.base_url, token: 'pat_x', token_type: :pat)
    begin
      tc = client2.tenant('acme').app('crm').data.discover('orders')
      assert_equal '/api/v1/apps/app_123/tables/orders', server2.last['path']
      assert_equal({ 'id' => 'uuid' }, tc.schema.columns)
    ensure
      server2.shutdown
    end
  end

  def test_discover_caches_across_chains
    # The schema cache is memoized on the client, so two discover() calls from
    # separate tenant().app() chains hit the inspect endpoint ONCE.
    set_response({ 'tableName' => 'orders', 'columns' => [{ 'name' => 'id', 'type' => 'uuid' }] })
    @server.reset_last
    @client.tenant('acme').app('crm').data.discover('orders')
    first = last['path']
    @server.reset_last
    @client.tenant('acme').app('crm').data.discover('orders')
    # Second discover served from cache: server saw no new request.
    assert_equal '/api/v1/tenants/acme/apps/crm/tables/orders/inspect', first
    assert_equal({}, last)
  end

  def test_discover_404_becomes_table_not_found
    # appId path: /api/v1/apps 404 -> resolve fails; slug inspect 404 too ->
    # normalized to TableNotFoundError.
    set_response({ 'error' => { 'code' => 'not_found', 'category' => 'not_found' } }, status: 404)
    assert_raises(TableNotFoundError) { @client.tenant('acme').app('crm').data.discover('ghosts') }
  end
end

# Mock server whose /api/v1/apps returns a matching app so the appId path wins.
class AppIdAwareServer < MockDataServer
  private

  def handle(conn)
    request_line = conn.gets
    return conn.close if request_line.nil?

    method, target, = request_line.split(' ')
    while (line = conn.gets)
      break if line.chomp.empty?
    end
    uri = URI.parse("http://x#{target}")
    @last = { 'method' => method, 'path' => uri.path }
    body = if uri.path == '/api/v1/apps'
             { 'items' => [{ 'id' => 'app_123', 'slug' => 'crm' }] }
           else
             { 'tableName' => 'orders', 'columns' => [{ 'name' => 'id', 'type' => 'uuid' }] }
           end
    payload = JSON.generate(body)
    conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  ensure
    conn.close
  end
end

class SchemaCacheTest < Minitest::Test
  def test_get_or_set_caches
    cache = SchemaCache.new
    calls = { n: 0 }
    loader = lambda do
      calls[:n] += 1
      define_schema('orders', { 'id' => 'uuid' })
    end
    cache.get_or_set('k') { loader.call }
    cache.get_or_set('k') { loader.call }
    assert_equal 1, calls[:n]
    cache.invalidate('k')
    cache.get_or_set('k') { loader.call }
    assert_equal 2, calls[:n]
  end

  def test_lru_eviction
    cache = SchemaCache.new(max_entries: 2)
    %w[a b c].each { |k| cache.set(k, define_schema(k, { 'id' => 'uuid' })) }
    assert_nil cache.get('a') # evicted
    refute_nil cache.get('c')
  end
end

class LikeGuardTest < Minitest::Test
  def test_contains_escapes_wildcards
    expr = where('name').like.contains('50%_off')
    assert_equal '%50\\%\\_off%', expr[:value]
  end

  def test_like_raw_redos_guard
    assert_raises(ValidationError) { where('name').like.raw('%%%%x') }
  end
end

class BlockFormTest < Minitest::Test
  def test_where_block_form_returns_expr
    assert_equal({ op: :eq, column: 'status', value: 'paid' }, where(:status) { |c| c.eq('paid') })
  end

  def test_symbol_column_normalizes_to_string_key
    assert_equal({ 'status' => 'eq.paid' }, serialize_where(where(:status).eq('paid')))
  end
end
