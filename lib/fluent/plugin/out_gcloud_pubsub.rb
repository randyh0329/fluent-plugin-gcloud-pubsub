require 'google/apis/pubsub_v1'
require 'fluent/output'

module Fluent
  class GcloudPubSubOutput < BufferedOutput
    Fluent::Plugin.register_output('gcloud_pubsub', self)
    Pubsub = Google::Apis::PubsubV1

    config_set_default :buffer_type,                'lightening'
    config_set_default :flush_interval,             1
    config_set_default :try_flush_interval,         0.05
    config_set_default :buffer_chunk_records_limit, 900
    config_set_default :buffer_chunk_limit,         9437184
    config_set_default :buffer_queue_limit,         64

    config_param :project,            :string,  :default => nil
    config_param :topic,              :string,  :default => nil
    config_param :key,                :string,  :default => nil
    config_param :autocreate_topic,   :bool,    :default => false

    unless method_defined?(:log)
      define_method("log") { $log }
    end

    unless method_defined?(:router)
      define_method("router") { Fluent::Engine }
    end

    def configure(conf)
      super

      raise Fluent::ConfigError, "'topic' must be specified." unless @topic
    end

    def start
      super

      @pubsub = Pubsub::PubsubService.new
      @pubsub.authorization = Google::Auth.get_application_default([Pubsub::AUTH_PUBSUB])
      @topic_path = "projects/#{@project}/topics/#{@topic}"

      if @autocreate_topic
        @pubsub.create_topic(@topic_path)
      end


    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      request = Pubsub::PublishRequest.new(messages: [])
      chunk.msgpack_each do |tag, time, record|
        request.messages << Pubsub::Message.new(data: record.to_json)
      end

      if request.messages.length > 0
        @pubsub.publish_topic(@topic_path, request)
      end
    rescue => e
      log.error "unexpected error", :error=>$!.to_s
      log.error_backtrace
      raise e
    end
  end
end
