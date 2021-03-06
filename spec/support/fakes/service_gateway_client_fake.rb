module VCAP::Services::Api
  class ServiceGatewayClientFake < ServiceGatewayClient
    def provision(*)
      GatewayHandleResponse.decode({
        :service_id => "SERVICE_ID",
        :configuration => "CONFIGURATION",
        :credentials => {"password" => "PASSWORD"},
      }.to_json)
    end

    def unprovision(*)
    end

    def bind(*)
      GatewayHandleResponse.decode({
        :service_id => "SERVICE_ID",
        :configuration => "CONFIGURATION",
        :credentials => {"password" => "PASSWORD"},
      }.to_json)
    end
  end
end
