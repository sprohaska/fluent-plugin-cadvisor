require 'rest_client'
require 'time'

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

  config_param :host, :string, :default => 'localhost'
  config_param :port, :string, :default => 8080
  config_param :api_version, :string, :default => '1.1'
  config_param :stats_interval, :time, :default => 10 # every minute
  config_param :tag_prefix, :string, :default => "metric"

  def initialize
    super
    require 'socket'
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

  def get_spec
    response = RestClient.get(@cadvisorEP + "/machine")
    JSON.parse(response.body)
  end

  # Metrics collection methods
  def get_metrics
    list_container_ids.each do |obj|
      emit_container_info(obj)
    end
  end

  def list_container_ids
    socket_path = "/var/run/docker.sock"
    if File.exists?(socket_path)
      socket = Socket.unix(socket_path)
      socket.puts("GET /containers/json HTTP/1.0\n\r")

      res = socket.readlines
      socket.close

      #Remove HTTP Headers and parse the body
      jsn = JSON.parse(res.to_a[5..-1].join)
      jsn.collect { |obj| {:id => obj['Id'], :name => obj['Image']} }
    else
      []
    end
  end

  def emit_container_info(obj)
    id = obj[:id]
    response = RestClient.get(@cadvisorEP + "/containers/docker/" + id)
    res = JSON.parse(response.body)

    # Set max memory
    memory_limit = @machine['memory_capacity'] < res['spec']['memory']['limit'] ? @machine['memory_capacity'] : res['spec']['memory']['limit']

    prev = @dict[id] ||= 0
    res['stats'].each do | stats |
      timestamp = Time.parse(stats['timestamp']).to_i
      break if timestamp < prev

      @dict[id] = timestamp

      record = {
        'container_id'       => id,
        'image'              => obj[:name],
        'memory_current'     => stats['memory']['usage'],
        'memory_limit'       => memory_limit,
        'cpu_usage'          => stats['cpu']['usage']['total'],
        'cpu_num_cores'      => stats['cpu']['usage']['per_cpu_usage'].count,
        'network_rx_bytes'   => stats['network']['rx_bytes'],
        'network_rx_packets' => stats['network']['rx_packets'],
        'network_rx_errors'  => stats['network']['rx_errors'],
        'network_rx_dropped' => stats['network']['rx_dropped'],
        'network_tx_bytes'   => stats['network']['tx_bytes'],
        'network_tx_packets' => stats['network']['tx_packets'],
        'network_tx_errors'  => stats['network']['tx_errors'],
        'network_tx_dropped' => stats['network']['tx_dropped'],
      }

      Fluent::Engine.emit("stats", timestamp, record)
    end
  end

  def shutdown
    @loop.stop
    @thread.join
  end
end

