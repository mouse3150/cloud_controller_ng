# Copyright (c) 2009-2012 VMware, Inc.

require "vcap/stager/client"
require "redis"
require "cloud_controller/staging_task_log"

module VCAP::CloudController
  module AppStager
    class AsyncResponse < Struct.new(:task_id, :streaming_log_url, :error)
      def self.from_json(json)
        if json
          hash = Yajl::Parser.parse(json)
          new(*hash.values_at("task_id", "streaming_log_url", "error"))
        else
          new(nil, nil, "Did not receive staging response")
        end
      end

      def error?
        !!error
      end
    end

    class AsyncError < StandardError; end

    class << self
      attr_reader :config, :message_bus

      def configure(config, message_bus, redis_client = nil)
        @config = config
        @message_bus = message_bus
        @redis_client = redis_client || Redis.new(
          :host => @config[:redis][:host],
          :port => @config[:redis][:port],
          :password => @config[:redis][:password]
        )
      end

      def stage_app(app)
        logger.debug "staging #{app.guid}"
        LegacyStaging.with_upload_handle(app.guid) do |handle|
          client_error = nil
          results = EM.schedule_sync do |promise|
            client = VCAP::Stager::Client::EmAware.new(MessageBus.instance.nats.client, queue)

            request = staging_request(app)
            logger.debug "staging #{app.guid} request: #{request}"
            deferrable = client.stage(request, staging_timeout)

            deferrable.errback do |e|
              logger.error "staging #{app.guid} request: #{request} error #{e}"
              client_error = e
              promise.deliver(e)
            end

            deferrable.callback do |resp|
              logger.debug "staging #{app.guid} complete #{resp}"
              promise.deliver(resp)
            end
          end

          unless client_error
            StagingTaskLog.new(app.guid, results["task_log"], @redis_client).save
            upload_path = handle.upload_path
          end

          unless upload_path
            err_str = client_error || results["task_log"]
            raise Errors::StagingError.new(
              "failed to stage application:\n#{err_str}")
          end

          droplet_hash = Digest::SHA1.file(upload_path).hexdigest
          LegacyStaging.store_droplet(app.guid, upload_path)
          app.droplet_hash = droplet_hash
          app.save
        end

        logger.info "staging for #{app.guid} complete"
      end

      def stage_app_async(app)
        responses = message_bus.request(
          "staging.async",
          json_staging_request(app),
          :expected => 1
        )

        AsyncResponse.from_json(responses.first).tap do |r|
          raise AsyncError if r.error?
        end
      end

      def delete_droplet(app)
        LegacyStaging.delete_droplet(app.guid)
      end

      def staging_request(app)
        {
          :app_id       => app.guid,
          :properties   => staging_task_properties(app),
          :download_uri => LegacyStaging.app_uri(app.guid),
          :upload_uri   => LegacyStaging.droplet_upload_uri(app.guid)
        }
      end

      private

      def json_staging_request(app)
        Yajl::Encoder.encode(staging_request(app))
      end

      def staging_task_properties(app)
        {
          :services    => app.service_bindings.map { |sb| service_binding_to_staging_request(sb) },
          :framework      => app.framework.name,
          :framework_info => app.framework.internal_info,

          :buildpack => app.buildpack,

          :resources   => {
            :memory => app.memory,
            :disk   => app.disk_quota,
            :fds    => app.file_descriptors
          },

          :environment => (app.environment_json || {}).map {|k,v| "#{k}=#{v}"},
          :meta => app.metadata
        }
      end

      def service_binding_to_staging_request(sb)
        instance = sb.service_instance
        plan = instance.service_plan
        service = plan.service

        {
          :label        => "#{service.label}-#{service.version}",
          :tags         => {}, # TODO: can this be removed?
          :name         => instance.name,
          :credentials  => sb.credentials,
          :options      => sb.binding_options || {},
          :plan         => instance.service_plan.name,
          :plan_options => {} # TODO: can this be removed?
        }
      end

      def queue
        @config[:staging] && @config[:staging][:queue] || "staging"
      end

      def staging_timeout
        @config[:staging] && @config[:staging][:max_staging_runtime] || 120
      end

      def droplets_path
        unless @droplets_path
          # TODO: remove this tmpdir.  It is for use when running under vcap
          # for development
          @droplets_path = @config[:directories] && @config[:directories][:droplets]
          @droplets_path ||= Dir.mktmpdir
          FileUtils.mkdir_p(@droplets_path) unless File.directory?(@droplets_path)
        end
        @droplets_path
      end

      def logger
        @logger ||= Steno.logger("cc.app_stager")
      end
    end
  end
end
