# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'json'
require 'time'
require 'timeout'
require 'axhub_sdk'

unless ENV['AXHUB_LIVE_ALL_METHODS'] == '1'
  warn 'live prod all-method sweep is opt-in'
  exit 0
end

TOKEN = ENV.fetch('AXHUB_TOKEN')
TENANT_ID = ENV.fetch('AXHUB_LIVE_TENANT_ID', 'cc1e58f1-8e46-4ac7-96c1-190c4cdd5b70')
TENANT_SLUG = ENV.fetch('AXHUB_LIVE_TENANT_SLUG', 'test')
BASE_URL = ENV.fetch('AXHUB_LIVE_BASE_URL', 'https://api.axhub.ai')
DEAD_UUID = '00000000-0000-4000-8000-00000000dead'
PATH_PARAM_RE = /\{([^}]+)\}/
LIVE_CALL_TIMEOUT = Float(ENV.fetch('AXHUB_LIVE_CALL_TIMEOUT_SECONDS', '1.5'))

HIGH_RISK_TENANT_OPS = {
  'tenantsDeleteApiV1TenantsByTenantID' => true,
  'tenantsPatchApiV1TenantsByTenantID' => true,
  'tenantsDeleteApiV1TenantsByTenantIDIcon' => true,
  'gatewayGetApiV1TenantsByTenantIDConnectorsByConnectorIDDiscover' => true,
  'gatewayPostApiV1TenantsByTenantIDConnectors' => true
}.freeze

HIGH_RISK_APP_OPS = {
  'appsDeleteApiV1AppsByAppID' => true,
  'appsDeleteApiV1AppsByAppIDPermanent' => true,
  'deployPostApiV1AppsByAppIDDeploymentsByDidCancel' => true,
  'deployPostApiV1AppsByAppIDDeploymentsByDidRollback' => true
}.freeze

def path_param_value(name, operation_id, fixture)
  case name
  when 'tenantID'
    HIGH_RISK_TENANT_OPS[operation_id] ? DEAD_UUID : TENANT_ID
  when 'tenantSlug'
    TENANT_SLUG
  when 'appID'
    HIGH_RISK_APP_OPS[operation_id] ? DEAD_UUID : fixture.fetch('appID', DEAD_UUID)
  when 'appSlug'
    fixture.fetch('appSlug', 'sdk-e2e-missing-app')
  when 'table', 'tableName'
    'sdk_e2e_missing_table'
  when 'path'
    'sdk/e2e/missing'
  when 'domain'
    'sdk-e2e.invalid'
  when 'providerID'
    operation_id == 'authGetAuthByProviderIDStart' ? 'github' : 'sdk-e2e-provider'
  when 'patID'
    DEAD_UUID
  when 'key'
    'SDK_E2E_NOOP'
  when 'connector'
    'sdk-e2e-connector'
  else
    DEAD_UUID
  end
end

def path_params_for(route, fixture)
  route['path'].scan(PATH_PARAM_RE).flatten.uniq.to_h do |name|
    [name, path_param_value(name, route['operationId'], fixture)]
  end
end

def body_for(route)
  return nil if %w[GET DELETE].include?(route['method'])

  { sdk_e2e: true, operation_id: route['operationId'] }
end

raise "route coverage drift #{AxHub::ROUTES.size}" unless AxHub::ROUTES.size == 189
raise 'operation metadata drift' unless AxHub::OPERATION_METHODS.size == AxHub::ROUTES.size

client = AxHub::Client.new(base_url: BASE_URL, token: TOKEN, token_type: :pat, default_tenant_id: TENANT_ID, default_tenant_slug: TENANT_SLUG, timeout_seconds: LIVE_CALL_TIMEOUT)
fixture = {}
created_fixture = false
begin
  created = Timeout.timeout(LIVE_CALL_TIMEOUT) do
    client.apps.create(slug: "sdk-e2e-destructive-rb-#{Time.now.to_i}", name: 'SDK destructive E2E disposable')
  end
  fixture['appID'] = created['id'] || created['appId'] || created['appID']
  fixture['appSlug'] = created['slug']
  created_fixture = !fixture['appID'].nil? && !fixture['appID'].empty?
rescue AxHub::Error => e
  fixture['fixture_error'] = { status: e.status, code: e.code, category: e.category }
rescue Timeout::Error => e
  fixture['fixture_error'] = { status: 0, code: 'network_timeout', category: 'network', message: e.message }
end

route_by_operation = AxHub::ROUTES.to_h { |route| [route['operationId'], route] }
contexts = {
  'apps' => client.apps,
  'identity' => client.identity,
  'tenants' => client.tenants,
  'authz' => client.authz,
  'audit' => client.audit,
  'gateway' => client.gateway,
  'cost' => client.cost,
  'data' => client.data,
  'deployments' => client.deployments
}

results = []
begin
  AxHub::OPERATION_METHODS.each_with_index do |item, index|
    route = route_by_operation.fetch(item['operationId'])
    result = { operationId: item['operationId'], method: route['method'], kind: 'unknown' }
    warn "ruby live #{index + 1}/#{AxHub::OPERATION_METHODS.size} #{item['operationId']}" if ENV['AXHUB_LIVE_PROGRESS'] == '1'
    begin
      Timeout.timeout(LIVE_CALL_TIMEOUT) do
        contexts.fetch(item['context']).public_send(item['snake'], path_params: path_params_for(route, fixture), query: { 'sdk_e2e' => 'live_all_methods' }, body: body_for(route))
      end
      result[:kind] = 'success'
    rescue AxHub::Error => e
      result.merge!(kind: 'axhub_error', status: e.status, code: e.code, category: e.category, server_error: e.status >= 500)
    rescue Timeout::Error => e
      result.merge!(kind: 'axhub_error', status: 0, code: 'network_timeout', category: 'network', server_error: false, error: e.message)
    rescue StandardError => e
      result.merge!(kind: 'exception', exception: e.class.name, error: e.message)
    end
    results << result
  end
ensure
  if created_fixture && fixture['appID']
    %w[appsDeleteApiV1AppsByAppID appsDeleteApiV1AppsByAppIDPermanent].each do |operation_id|
      Timeout.timeout(LIVE_CALL_TIMEOUT) { client.request(operation_id, path_params: { appID: fixture['appID'] }) }
    rescue AxHub::Error
      nil
    rescue Timeout::Error
      nil
    end
  end
end

summary = {
  sdk: 'ruby',
  baseUrl: BASE_URL,
  tenantId: TENANT_ID,
  fixture: { created: created_fixture, appID: fixture['appID'], appSlug: fixture['appSlug'] },
  total: results.size,
  destructive: results.count { |r| r[:method] != 'GET' },
  success: results.count { |r| r[:kind] == 'success' },
  axhub_error: results.count { |r| r[:kind] == 'axhub_error' },
  exception: results.count { |r| r[:kind] == 'exception' },
  server_errors: results.select { |r| r[:server_error] },
  exceptions: results.select { |r| r[:kind] == 'exception' },
  results: results
}

if ENV['AXHUB_LIVE_RESULT_PATH']
  File.open(ENV.fetch('AXHUB_LIVE_RESULT_PATH'), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.write(JSON.pretty_generate(summary))
  end
end

raise "total drift #{summary[:total]}" unless summary[:total] == 189
expected_destructive = AxHub::ROUTES.count { |route| route['method'] != 'GET' }
raise "destructive method count drift #{summary[:destructive]} != #{expected_destructive}" unless summary[:destructive] == expected_destructive
raise "exceptions: #{summary[:exceptions].inspect}" unless summary[:exceptions].empty?
raise "server errors: #{summary[:server_errors].inspect}" unless summary[:server_errors].empty?

puts "ruby live all operation facade e2e ok #{summary[:total]} routes"
