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

def vector_files
  dirs = []
  dirs << ENV['AXHUB_CONFORMANCE_DIR'] if ENV['AXHUB_CONFORMANCE_DIR']
  dirs << File.expand_path('../testdata/conformance/vectors', __dir__)
  dirs << File.expand_path('../../conformance/vectors', __dir__)
  dirs << File.expand_path('../../../axhub-sdk-spec/conformance/vectors', __dir__)
  dirs.each do |dir|
    files = Dir[File.join(dir, '*.json')].sort
    return files unless files.empty?
  end
  []
end

def dispatch(client, v)
  call = v['call']
  case call['symbol']
  when 'sdk.apps.create'
    client.apps.create(**(call['args'] || {}).transform_keys(&:to_sym))
  when 'sdk.operation'
    client.public_send(call['context']).public_send(call['method'], path_params: call['pathParams'] || {}, query: call['query'] || {}, body: call['body'])
  when 'sdk.redactedToken'
    { 'redactedToken' => client.redacted_token }
  else
    raise "unknown vector symbol #{call['symbol']}"
  end
end

vectors = vector_files
raise 'no vectors' if vectors.empty?

vectors.each do |file|
  v = JSON.parse(File.read(file))
  seen = {}
  server = TCPServer.new('127.0.0.1', 0)
  port = server.addr[1]
  thread = Thread.new do
    socket = server.accept
    request = socket.readpartial(8192)
    lines = request.lines
    method, path = lines[0].split[0, 2]
    headers = lines.drop(1).take_while { |l| l.strip != '' }.map { |l| k, val = l.split(':', 2); [k.downcase, val&.strip] }.to_h
    seen[:method] = method; seen[:path] = path.split('?').first; seen[:headers] = headers
    response = v['mockResponse'] || { 'status' => 200, 'body' => {} }
    body = JSON.generate(response['body'] || {})
    socket.write "HTTP/1.1 #{response['status'] || 200} OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    socket.close
  end
  client = AxHub::Client.new(base_url: "http://127.0.0.1:#{port}", token: v.fetch('client', {})['token'], token_type: v.fetch('client', {})['tokenType']&.to_sym, default_tenant_id: v.fetch('client', {})['defaultTenantId'], default_tenant_slug: v.fetch('client', {})['defaultTenantSlug'])
  begin
    got = dispatch(client, v)
    Assert.ok(v['expect'].key?('ok'), "#{file} expected ok")
    v['expect']['ok'].each { |k, want| Assert.eq(got[k], want, "#{file} #{k}") }
  rescue AxHub::Error => e
    Assert.ok(v['expect'].key?('error'), "#{file} unexpected error #{e.code}")
    want = v['expect']['error']
    Assert.eq([e.category, e.code], [want['category'], want['code']], "#{file} error")
    Assert.eq(e.request_id, want['requestId'], "#{file} request id") if want.key?('requestId')
    Assert.eq(e.retryable, want['retryable'], "#{file} retryable") if want.key?('retryable')
  ensure
    if thread.alive?
      thread.kill unless v['httpExpect']
      thread.join(1)
    end
    begin
      server.close
    rescue IOError, SystemCallError
      # already closed by test cleanup
    end
  end
  if v['httpExpect']
    Assert.eq(seen[:method], v['httpExpect']['method'], "#{file} method")
    Assert.eq(seen[:path], v['httpExpect']['path'], "#{file} path")
    (v['httpExpect']['headersInclude'] || []).each { |h| Assert.ok(seen[:headers][h], "#{file} header #{h}") }
    (v['httpExpect']['headersExact'] || {}).each { |h, want| Assert.eq(seen[:headers][h], want, "#{file} header #{h}") }
  else
    Assert.eq(seen, {}, "#{file} expected no request")
  end
end
puts "ruby conformance ok #{vectors.size} vectors"
