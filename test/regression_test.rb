# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'json'
require 'socket'
require 'axhub_sdk'

module Assert
  def self.eq(actual, expected, message)
    raise "#{message}: expected=#{expected.inspect} actual=#{actual.inspect}" unless actual == expected
  end
  def self.ok(value, message)
    raise message unless value
  end
end

server = TCPServer.new('127.0.0.1', 0)
port = server.addr[1]
seen = {}
thread = Thread.new do
  socket = server.accept
  request = socket.readpartial(4096)
  lines = request.lines
  method, path = lines[0].split[0, 2]
  headers = lines.drop(1).take_while { |l| l.strip != '' }.map { |l| k, v = l.split(':', 2); [k.downcase, v&.strip] }.to_h
  seen[:method] = method; seen[:path] = path; seen[:api_key] = headers['x-api-key']; seen[:request_id] = headers['x-request-id']
  body = { id: 'app_1', tenant_id: 'tnt_1', slug: 'my-app', schema_name: 'app_my-app' }.to_json
  socket.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
  socket.close
end
client = AxHub::Client.new(base_url: "http://127.0.0.1:#{port}", token: 'pat_x', token_type: :pat, default_tenant_id: 'tnt_1')
got = client.apps.create(slug: 'my-app', name: 'My App')
thread.join
Assert.eq(got['id'], 'app_1', 'id')
Assert.eq(got['schemaName'], 'app_my-app', 'schemaName')
Assert.eq(seen[:path], '/api/v1/tenants/tnt_1/apps', 'path')
Assert.eq(seen[:api_key], 'pat_x', 'api key')
Assert.ok(seen[:request_id], 'request id')

begin
  AxHub::Client.new(base_url: 'http://127.0.0.1:1', token: 'pat_x', token_type: :pat).apps.create(slug: 'my-app')
  raise 'expected tenant error'
rescue AxHub::Error => e
  Assert.eq([e.category, e.code], ['tenant_id_required', 'tenant_id_required'], 'tenant error')
end
Assert.eq(AxHub::ROUTES.size, 177, 'route coverage')
Assert.eq(AxHub::ERROR_CODES.size, 42, 'error coverage')
Assert.eq(AxHub::ERROR_CODES['slug_taken'].category, 'conflict', 'slug_taken category')
puts 'ruby regression ok'


error_server = TCPServer.new('127.0.0.1', 0)
error_port = error_server.addr[1]
error_thread = Thread.new do
  socket = error_server.accept
  socket.readpartial(4096)
  body = { error: { category: 'unauthenticated', code: 'token_expired', message: 'expired', request_id: 'req_rb' } }.to_json
  socket.write "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
  socket.close
end
error_client = AxHub::Client.new(base_url: "http://127.0.0.1:#{error_port}", token: 'pat_secret', token_type: :pat)
Assert.eq(error_client.redacted_token, '***REDACTED***', 'redacted token')
begin
  error_client.request('appsGetApiV1AppsByAppID', path_params: { appID: 'app_1' })
  raise 'expected error metadata error'
rescue AxHub::Error => e
  Assert.eq(e.request_id, 'req_rb', 'error metadata request id')
  Assert.ok(e.retryable, 'retryable fallback')
end
error_thread.join
error_server.close
%w[apps identity tenants authz audit gateway data deployments].each { |name| Assert.ok(!AxHub::CONTEXT_ROUTES[name].empty?, "context routes #{name}") }
puts 'ruby error metadata and context ok'

non_json_server = TCPServer.new('127.0.0.1', 0)
non_json_port = non_json_server.addr[1]
non_json_thread = Thread.new do
  2.times do
    socket = non_json_server.accept
    request = socket.readpartial(4096)
    path = request.lines.first.split[1]
    if path.start_with?('/auth/google_oauth2/start')
      body = '<html>oauth redirect target</html>'
      socket.write "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    else
      body = '"invalid_request"'
      socket.write "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    end
    socket.close
  end
end
non_json_client = AxHub::Client.new(base_url: "http://127.0.0.1:#{non_json_port}")
Assert.eq(non_json_client.request('authGetAuthGoogleOauth2Start')['raw'], '<html>oauth redirect target</html>', 'non-json success raw')
begin
  non_json_client.request('authPostOauthToken', body: { noop: true })
  raise 'expected scalar error body error'
rescue AxHub::Error => e
  Assert.eq([e.status, e.code], [400, 'http_400'], 'scalar error body')
end
non_json_thread.join
non_json_server.close
puts 'ruby non-json response handling ok'
