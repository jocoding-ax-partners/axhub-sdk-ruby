# frozen_string_literal: true

# Ergonomic data layer demo (mirrors node examples/data-crud-demo.ts +
# data-projection.ts + data-discover-demo.ts, and the python data_crud_demo.py).
#
# Run against a live AX Hub backend:
#
#   AX_HUB_BASE_URL=https://api.axhub.ai \
#   AX_HUB_PAT=pat_xxx \
#   AX_HUB_TENANT=acme AX_HUB_APP=crm \
#   ruby -Ilib examples/data_crud_demo.rb
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'axhub_sdk'

include AxHub::Data # where / and_ / define_schema convenience

def main
  sdk = AxHub::Client.new(
    base_url: ENV.fetch('AX_HUB_BASE_URL', 'https://api.axhub.ai'),
    token: ENV.fetch('AX_HUB_PAT', 'demo'),
    token_type: :pat
  )

  tenant = ENV.fetch('AX_HUB_TENANT', 'acme')
  app = ENV.fetch('AX_HUB_APP', 'crm')

  # 1. Static schema + fluent table client (node: sdk.tenant().app().data.table()).
  orders = define_schema(
    'orders',
    {
      'id' => 'uuid',
      'total' => 'number',
      'status' => { type: 'enum', values: %w[paid pending] }
    }
  )
  table = sdk.tenant(tenant).app(app).data.table(orders)

  # 2. count() with a pushable predicate.
  puts "paid order count: #{table.count(where: where(orders.cols['status']).eq('paid'))}"

  # 3. list() with where + order_by + select + offset pagination.
  page1 = table.list(
    where: and_(where('status').eq('paid'), where('total').gte(10)),
    order_by: '-total',
    select: %w[id total],
    page: 1,
    page_size: 10
  )
  puts "page 1 items: #{page1.items.inspect} next_cursor: #{page1.next_cursor.inspect}"

  # 4. insert / get / update / delete round-trip.
  created = table.insert({ 'total' => 42, 'status' => 'pending' })
  fetched = table.get(created['id'])
  table.update(created['id'], { 'status' => 'paid' })
  table.delete(created['id'])
  puts "round-trip id: #{fetched['id']}"

  # 5. Runtime schema discovery (node: data.discover()).
  discovered = sdk.tenant(tenant).app(app).data.discover('orders')
  cols = discovered.schema ? discovered.schema.columns.keys : []
  puts "discovered columns: #{cols.inspect}"

  # 6. list_all() drains every page; emits a drift marker if the backend grows.
  table.list_all(where: where('status').eq('paid'), page_size: 50) do |entry|
    case entry.type
    when :item
      # use(entry.value)
    when :drift
      puts "backend grew mid-scan by #{entry.added_since}"
    end
  end
end

main if $PROGRAM_NAME == __FILE__
