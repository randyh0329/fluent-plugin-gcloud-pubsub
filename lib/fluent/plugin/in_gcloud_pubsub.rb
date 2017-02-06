require 'google/apis/pubsub_v1'
require 'fluent/input'
require 'fluent/parser'

module Fluent
  class GcloudPubSubInput < Input
    Fluent::Plugin.register_input('gcloud_pubsub', self)
    Pubsub = Google::Apis::PubsubV1

    config_param :tag,                :string
    config_param :project,            :string,  :default => nil
    config_param :topic,              :string,  :default => nil
    config_param :subscription,       :string,  :default => nil
    config_param :key,                :string,  :default => nil
    config_param :pull_interval,      :integer, :default => 5
    config_param :max_messages,       :integer, :default => 100
    config_param :return_immediately, :bool,    :default => true

    unless method_defined?(:log)
      define_method("log") { $log }
    end

    unless method_defined?(:router)
      define_method("router") { Fluent::Engine }
    end

    def configure(conf)
      super

      raise Fluent::ConfigError, "'topic' must be specified." unless @topic
      raise Fluent::ConfigError, "'subscription' must be specified." unless @subscription

      configure_parser(conf)
    end

    def configure_parser(conf)
      @parser = Fluent::TextParser.new
      @parser.configure(conf)
    end

    def start
      super

      @pubsub = Pubsub::PubsubService.new
      @pubsub.authorization = Google::Auth.get_application_default([Pubsub::AUTH_PUBSUB])
	
      @subscription_full = "projects/#{@project}/subscriptions/#{@subscription}"

      @stop_subscribing = false
      @subscribe_thread = Thread.new(&method(:subscribe))
    end

    def shutdown
      super

      @stop_subscribing = true
      @subscribe_thread.join
    end

    private
    def configure_parser(conf)
      @parser = Fluent::TextParser.new
      @parser.configure(conf)
    end

    def subscribe
      until @stop_subscribing
        response = @pubsub.pull_subscription(@subscription_full, Pubsub::PullRequest.new(max_messages: @max_messages, return_immediately: @return_immediately))
        messages = response.received_messages  
        if !messages.nil? && messages.length > 0
          es = parse_messages(messages)
          unless es.empty?
            begin
              router.emit_stream(@tag, es)
            rescue
              # ignore errors. Engine shows logs and backtraces.
            end
            ack_ids = response.received_messages.map{ |msg| msg.ack_id }
            @pubsub.acknowledge_subscription(@subscription_full, Pubsub::AcknowledgeRequest.new(ack_ids: ack_ids))
	    log.debug "#{messages.length} message(s) processed"
          end
        end

        if @return_immediately
          sleep @pull_interval
        end
      end
    rescue
      log.error "unexpected error", :error=>$!.to_s
      log.error_backtrace
    end

    def parse_messages(messages)
      es = MultiEventStream.new
      messages.each do |m|
        convert_line_to_event(m.message.data, es)
      end
      es
    end

    def convert_line_to_event(line, es)
      line.chomp!  # remove \n
      @parser.parse(line) { |time, record|
        if time && record
          es.add(time, record)
        else
          log.warn "pattern not match: #{line.inspect}"
        end
      }
    rescue => e
      log.warn line.dump, :error => e.to_s
      log.debug_backtrace(e.backtrace)
    end
  end
end
