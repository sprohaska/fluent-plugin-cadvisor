require 'rest-client'
require 'digest/sha1'
require 'time'
require 'docker'

class CadvisorInput < Fluent::Input
  class TimerWatcher < Coolio::TimerWatcher

    def initialize(interval, repeat, log, &callback)
      @callback = callback
      @log = log
      super(interval, repeat)
    end
    def on_timer
      @callback.call
    rescue
      @log.error $!.to_s
      @log.error_backtrace
    end
  end

  Fluent::Plugin.register_input('cadvisor', self)

  config_param :tag, :string
  config_param :host, :string, :default => 'localhost'
  config_param :port, :string, :default => 8080
  config_param :api_version, :string, :default => '1.3'
  config_param :api_variant, :string, :default => 'container'
  config_param :stats_interval, :time, :default => 60 # every minute
  config_param :docker_url, :string,  :default => 'unix:///var/run/docker.sock'

  def initialize
    super
    require 'socket'

    Docker.url = @docker_url
    @hostname = Socket.gethostname
    @dict     = {}
  end

  def configure(conf)
    super
  end

  def start
    @cadvisorEP ||= "http://#{@host}:#{@port}/api/v#{@api_version}"
    @machine    ||= get_spec

    @loop = Coolio::Loop.new
    tw = TimerWatcher.new(@stats_interval, true, @log, &method(:get_metrics))
    tw.attach(@loop)
    @thread = Thread.new(&method(:run))
  end

  def run
    @loop.run
  rescue
    log.error "unexpected error", :error=>$!.to_s
    log.error_backtrace
  end

  def get_interval (current, previous)
    cur  = Time.parse(current).to_f
    prev = Time.parse(previous).to_f

    # to nano seconds
    (cur - prev) * 1000000000
  end

  def get_spec
    response = RestClient.get(@cadvisorEP + "/machine")
    JSON.parse(response.body)
  end

  # Metrics collection methods
  def get_metrics
    Docker::Container.all.each do |obj|
      emit_container_info(obj)
    end
  end

  def emit_container_info(obj)
    container_json = obj.json
    config = container_json['Config']

    id   = container_json['Id']
    name = container_json['Name']
    name.sub! /^[\/]/, ''  # Remove leading '/'
    image = config['Image']

    if @api_variant == 'container'
      # This works with Docker >= 1.10.x
      response = RestClient.get(@cadvisorEP + "/containers/docker/" + id)
      res = JSON.parse(response.body)
    else
      # This works with Docker <= 1.9.x
      response = RestClient.get(@cadvisorEP + "/docker/" + id)
      res = JSON.parse(response.body)
      res = res.values[0]
    end

    # Set max memory
    memory_limit = @machine['memory_capacity'] < res['spec']['memory']['limit'] ? @machine['memory_capacity'] : res['spec']['memory']['limit']

    latest_timestamp = @dict[id] ||= 0

    # Remove previously sent stats, keeping the latest as a base for the rate
    # computations.
    res['stats'].reject! do | stats |
      Time.parse(stats['timestamp']).to_i < latest_timestamp
    end

    res['stats'].each_with_index do | stats, index |
      next if index == 0

      timestamp = Time.parse(stats['timestamp']).to_i
      @dict[id] = timestamp

      num_cores = stats['cpu']['usage']['per_cpu_usage'].count

      # CPU percentage variables
      prev           = res['stats'][index - 1];
      raw_usage      = stats['cpu']['usage']['total'] - prev['cpu']['usage']['total']
      interval_in_ns = get_interval(stats['timestamp'], prev['timestamp'])

      to_MBps = 1e9 / interval_in_ns / 1e6
      to_persec = 1e9 / interval_in_ns
      net = stats['network']
      prevnet = prev['network']

      record = {
        'id' => Digest::SHA1.hexdigest("#{name}#{id}#{timestamp.to_s}"),

        'container_id_full' => id,
        'container_name' => name,
        'image' => image,
        'memory_limit' => memory_limit,
        'cpu_num_cores' => num_cores,

        'memory_usage' => stats['memory']['usage'],

        'cpu_usage_total' => stats['cpu']['usage']['total'],
        'cpu_usage_total_rate' => (raw_usage / interval_in_ns).round(3),
        'cpu_usage_total_pct' => (
          (((raw_usage / interval_in_ns ) / num_cores ) * 100).round(2)
        ),

        'network_rx_bytes' => net['rx_bytes'],
        'network_rx_MBps' => (
          (net['rx_bytes'] - prevnet['rx_bytes']) * to_MBps
        ).round(3),
        'network_rx_packets' => net['rx_packets'],
        'network_rx_packets_persec' => (
          (net['rx_packets'] - prevnet['rx_packets']) * to_persec
        ).round(3),
        'network_rx_errors' => net['rx_errors'],
        'network_rx_errors_persec' => (
          (net['rx_errors'] - prevnet['rx_errors']) * to_persec
        ).round(3),
        'network_rx_dropped' => net['rx_dropped'],
        'network_rx_dropped_persec' => (
          (net['rx_dropped'] - prevnet['rx_dropped']) * to_persec
        ).round(3),

        'network_tx_bytes' => net['tx_bytes'],
        'network_tx_MBps' => (
          (net['tx_bytes'] - prevnet['tx_bytes']) * to_MBps
        ).round(3),
        'network_tx_packets' => net['tx_packets'],
        'network_tx_packets_persec' => (
          (net['tx_packets'] - prevnet['tx_packets']) * to_persec
        ).round(3),
        'network_tx_errors' => net['tx_errors'],
        'network_tx_errors_persec' => (
          (net['tx_errors'] - prevnet['tx_errors']) * to_persec
        ).round(3),
        'network_tx_dropped' => net['tx_dropped'],
        'network_tx_dropped_persec' => (
          (net['tx_dropped'] - prevnet['tx_dropped']) * to_persec
        ).round(3),
      }

      Fluent::Engine.emit(@tag, timestamp, record)
    end
  end

  def shutdown
    @loop.stop
    @thread.join
  end
end

