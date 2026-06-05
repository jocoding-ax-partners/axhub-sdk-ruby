# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'axhub_sdk'

client = AxHub::Client.new(base_url: 'http://127.0.0.1:1')
contexts = {
  'apps' => client.apps, 'identity' => client.identity, 'tenants' => client.tenants, 'authz' => client.authz,
  'audit' => client.audit, 'gateway' => client.gateway, 'data' => client.data, 'deployments' => client.deployments
}
raise "operation metadata drift" unless AxHub::OPERATION_METHODS.size == AxHub::ROUTES.size
AxHub::OPERATION_METHODS.each do |item|
  raise "missing #{item['snake']} on #{item['context']}" unless contexts[item['context']].respond_to?(item['snake'])
end
puts "ruby operation facade coverage ok #{AxHub::OPERATION_METHODS.size} routes"
