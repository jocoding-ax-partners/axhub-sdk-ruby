# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'json'
require 'socket'
require 'thread'
require 'uri'
require 'axhub_sdk'

PATH_PARAM_RE = /\{([^}]+)\}/

def path_param_value(name)
  {
    'tenantID' => 'tnt_1',
    'tenantSlug' => 'test-tenant',
    'appID' => 'app_1',
    'appSlug' => 'app-slug',
    'table' => 'table_1',
    'tableName' => 'table_1',
    'path' => 'resource-path',
    'domain' => 'example.com'
  }.fetch(name, "#{name.downcase}_1")
end

def path_params_for(path)
  path.scan(PATH_PARAM_RE).flatten.uniq.to_h { |name| [name, path_param_value(name)] }
end

def render_path(path, params)
  path.gsub(PATH_PARAM_RE) { URI.encode_www_form_component(params[Regexp.last_match(1)]) }
end

def body_for(route)
  return nil if %w[GET DELETE].include?(route['method'])
  { operationId: route['operationId'], ok: true }
end

def read_http_request(socket)
  raw = +''
  raw << socket.readpartial(4096) until raw.include?("\r\n\r\n")
  header_text, body = raw.split("\r\n\r\n", 2)
  lines = header_text.lines
  headers = lines.drop(1).map { |line| key, value = line.split(':', 2); [key.downcase, value&.strip] }.to_h
  content_length = headers.fetch('content-length', '0').to_i
  body ||= +''
  body << socket.readpartial(content_length - body.bytesize) while body.bytesize < content_length
  [lines.first, headers, body]
end

server = TCPServer.new('127.0.0.1', 0)
port = server.addr[1]
expected_queue = Queue.new
failures = Queue.new
requests_seen = Queue.new
server_thread = Thread.new do
  loop do
    expected = expected_queue.pop
    break if expected == :stop
    socket = server.accept
    begin
      first_line, headers, = read_http_request(socket)
      method, request_target = first_line.split[0, 2]
      uri = URI("http://127.0.0.1#{request_target}")
      route = expected.fetch(:route)
      failures << "#{route['operationId']} method #{method} != #{route['method']}" unless method == route['method']
      failures << "#{route['operationId']} path #{uri.path} != #{expected.fetch(:path)}" unless uri.path == expected.fetch(:path)
      query = URI.decode_www_form(uri.query || '').to_h
      failures << "#{route['operationId']} missing e2e query" unless query['e2e'] == 'ok'
      failures << "#{route['operationId']} missing PAT header" unless headers['x-api-key'] == 'pat_e2e'
      failures << "#{route['operationId']} missing request id" if headers['x-request-id'].nil? || headers['x-request-id'].empty?
      requests_seen << route['operationId']
      body = { operation_id: route['operationId'], ok: true }.to_json
      socket.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    rescue StandardError => e
      failures << e.full_message
    ensure
      socket.close
    end
  end
end

begin
  raise "route coverage drift #{AxHub::ROUTES.size}" unless AxHub::ROUTES.size == 185
  raise 'operation metadata drift' unless AxHub::OPERATION_METHODS.size == AxHub::ROUTES.size

  route_by_operation = AxHub::ROUTES.to_h { |route| [route['operationId'], route] }
  client = AxHub::Client.new(base_url: "http://127.0.0.1:#{port}", token: 'pat_e2e', token_type: :pat)
  contexts = {
    'apps' => client.apps, 'identity' => client.identity, 'tenants' => client.tenants, 'authz' => client.authz,
    'audit' => client.audit, 'gateway' => client.gateway, 'cost' => client.cost, 'data' => client.data, 'deployments' => client.deployments
  }

  AxHub::OPERATION_METHODS.each do |item|
    route = route_by_operation.fetch(item['operationId'])
    params = path_params_for(route['path'])
    expected_queue << { route: route, path: render_path(route['path'], params) }
    result = contexts.fetch(item['context']).public_send(item['snake'], path_params: params, query: { 'e2e' => 'ok' }, body: body_for(route))
    raise "#{route['operationId']} response was not parsed/camelized: #{result.inspect}" unless result['operationId'] == route['operationId']
  end
  raise "expected #{AxHub::ROUTES.size} requests, saw #{requests_seen.size}" unless requests_seen.size == AxHub::ROUTES.size
  unless failures.empty?
    all_failures = []
    all_failures << failures.pop until failures.empty?
    raise all_failures.join("\n")
  end
  puts "ruby all operation facade e2e ok #{requests_seen.size} routes"
ensure
  expected_queue << :stop
  server_thread.join(5)
  server.close
end
