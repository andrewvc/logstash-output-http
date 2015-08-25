# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "logstash/json"
require "uri"
require "logstash/plugin_mixins/http_client"

class LogStash::Outputs::Http < LogStash::Outputs::Base
  include LogStash::PluginMixins::HttpClient

  VALID_METHODS = ["put", "post", "patch", "delete", "get", "head"]

  # This output lets you `PUT` or `POST` events to a
  # generic HTTP(S) endpoint
  #
  # Additionally, you are given the option to customize
  # the headers sent as well as basic customization of the
  # event json itself.

  config_name "http"

  # URL to use
  config :url, :validate => :string, :required => :true

  # DEPRECATED. Set 'ssl_certificate_validation' instead
  config :verify_ssl, :validate => :boolean, :default => true, :deprecated => true

  # The HTTP Verb. One of "put", "post", "patch", "delete", "get", "head"
  config :http_method, :validate => VALID_METHODS, :required => :true

  # Custom headers to use
  # format is `headers => ["X-My-Header", "%{host}"]`
  config :headers, :validate => :hash

  # Content type
  #
  # If not specified, this defaults to the following:
  #
  # * if format is "json", "application/json"
  # * if format is "form", "application/x-www-form-urlencoded"
  config :content_type, :validate => :string

  # This lets you choose the structure and parts of the event that are sent.
  #
  #
  # For example:
  # [source,ruby]
  #    mapping => {"foo", "%{host}", "bar", "%{type}"}
  config :mapping, :validate => :hash

  # Set the format of the http body.
  #
  # If form, then the body will be the mapping (or whole event) converted
  # into a query parameter string, e.g. `foo=bar&baz=fizz...`
  #
  # If message, then the body will be the result of formatting the event according to message
  #
  # Otherwise, the event is sent as json.
  config :format, :validate => ["json", "form", "message"], :default => "json"

  config :message, :validate => :string

  def register
    # Handle this deprecated option. TODO: remove the option
    @ssl_certificate_validation = @verify_ssl if @verify_ssl
    @http_method = @http_method.to_sym

    # We count outstanding requests with this queue
    # This queue tracks the requests to create backpressure
    # When this queue is empty no new requests may be sent,
    # tokens must be added back by the client on success
    @request_tokens = SizedQueue.new(@pool_max)
    @pool_max.times {|t| @request_tokens << true }

    @requests = Array.new

    if @content_type.nil?
      case @format
        when "form" ; @content_type = "application/x-www-form-urlencoded"
        when "json" ; @content_type = "application/json"
        when "message" ; @content_type = "text/plain"
      end
    end

    validate_format!
  end # def register

  def receive(event)
    return unless output?(event)

    body = event_body(event)

    # Block waiting for a token
    token = @request_tokens.pop

    # Send the request
    url = event.sprintf(@url)
    headers = event_headers(event)

    # Create an async request
    request = client.send(@http_method, url, body: body, headers: headers, async: true)

    # Invoke it using the Manticore Executor (CachedThreadPool) directly
    request_async_background(request)

    # Make sure we return the token to the pool
    request.on_complete do
      @request_tokens << token
    end

    request.on_success do |response|
      if response.code < 200 || response.code > 299
        log_failure(
          "Encountered non-200 HTTP code #{200}",
          :response_code => response.code,
          :url => url,
          :event => event)
      end
    end

    request.on_failure do |exception|
      log_failure("Could not fetch URL",
                  :url => url,
                  :method => @http_method,
                  :body => body,
                  :headers => headers,
                  :message => exception.message,
                  :class => exception.class.name,
                  :backtrace => exception.backtrace
      )
    end
  end

  private

  # This is split into a separate method mostly to help testing
  def log_failure(message, opts)
    #puts "FAILED #{message} #{opts}"
    @logger.error("[HTTP Output Failure] #{message}", opts)
  end

  # Manticore doesn't provide a way to attach handlers to background or async requests well
  # It wants you to use futures. The #async method kinda works but expects single thread batches
  # and background only returns futures.
  # Proposed fix to manticore here: https://github.com/cheald/manticore/issues/32
  def request_async_background(request)
    @method ||= client.executor.java_method(:submit, [java.util.concurrent.Callable.java_class])
    @method.call(request)
  end

  # Format the HTTP body
  def event_body(event)
    # TODO: Create an HTTP post data codec, use that here
    if @format == "json"
      LogStash::Json.dump(map_event(event))
    elsif @format == "message"
      event.sprintf(@message)
    else
      encode(map_event(event))
    end
  end

  def map_event(event)
    if @mapping
      @mapping.reduce({}) do |acc,kv|
        k,v = kv
        acc[k] = event.sprintf(v)
        acc
      end
    else
      event.to_hash
    end
  end

  def event_headers(event)
    headers = custom_headers(event) || {}
    headers["Content-Type"] = @content_type
    headers
  end

  def custom_headers(event)
    return nil unless @headers

    @headers.reduce({}) do |acc,kv|
      k,v = kv
      acc[k] = event.sprintf(v)
      acc
    end
  end

  #TODO Extract this to a codec
  def encode(hash)
    return hash.collect do |key, value|
      CGI.escape(key) + "=" + CGI.escape(value.to_s)
    end.join("&")
  end


  def validate_format!
    if @format == "message"
      if @message.nil?
        raise "message must be set if message format is used"
      end

      if @content_type.nil?
        raise "content_type must be set if message format is used"
      end

      unless @mapping.nil?
        @logger.warn "mapping is not supported and will be ignored if message format is used"
      end
    end
  end
end
