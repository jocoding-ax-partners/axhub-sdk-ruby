# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'json'; require 'socket'; require 'axhub_sdk'

if ENV['AXHUB_TOKEN'] && !ENV['AXHUB_TOKEN'].empty?
  client = AxHub::Client.new(
    base_url: ENV.fetch('AXHUB_BASE_URL', 'https://api.axhub.ai'),
    token: ENV.fetch('AXHUB_TOKEN'),
    token_type: ENV.fetch('AXHUB_TOKEN_TYPE').to_sym,
    default_tenant_id: ENV['AXHUB_TENANT_ID']
  )
  got = client.identity.auth_get_api_v1_me
  puts "ruby prod test app ok #{client.base_url} keys=#{got.size}"
else
  server = TCPServer.new('127.0.0.1', 0); port = server.addr[1]
  thread = Thread.new do
    s = server.accept; s.readpartial(4096); body = { id: 'app_demo', tenant_id: 'tnt_demo', slug: 'demo', schema_name: 'app_demo' }.to_json; s.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"; s.close
  end
  client = AxHub::Client.new(base_url: "http://127.0.0.1:#{port}", token: 'pat_demo', token_type: :pat, default_tenant_id: 'tnt_demo')
  got = client.apps.create(slug: 'demo', name: 'Demo'); thread.join; puts "ruby test app ok #{got['id']} #{client.base_url}"
end
