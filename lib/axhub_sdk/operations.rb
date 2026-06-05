# frozen_string_literal: true

module AxHub
  def self.operation_method_name(operation_id)
    operation_id.gsub(/(.)([A-Z][a-z]+)/, '\\1_\\2').gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase
  end

  OPERATION_METHODS = ROUTES.map do |route|
    { 'operationId' => route['operationId'], 'context' => context_name(route), 'snake' => operation_method_name(route['operationId']) }
  end

  class OperationClient
    def initialize(client)
      @client = client
    end
  end

  class Client
    attr_reader :identity, :tenants, :authz, :audit, :gateway, :data, :deployments
    alias __axhub_original_initialize initialize unless method_defined?(:__axhub_original_initialize)
    def initialize(*args, **kwargs)
      __axhub_original_initialize(*args, **kwargs)
      @identity = OperationClient.new(self)
      @tenants = OperationClient.new(self)
      @authz = OperationClient.new(self)
      @audit = OperationClient.new(self)
      @gateway = OperationClient.new(self)
      @data = OperationClient.new(self)
      @deployments = OperationClient.new(self)
    end
  end

  def self.install_operation_methods
    OPERATION_METHODS.each do |item|
      target = item['context'] == 'apps' ? AppsClient : OperationClient
      target.define_method(item['snake']) do |path_params: {}, query: {}, body: nil|
        @client.request(item['operationId'], path_params: path_params, query: query, body: body)
      end
    end
  end

  install_operation_methods
end
