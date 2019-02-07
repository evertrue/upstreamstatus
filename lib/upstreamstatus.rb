require 'upstreamstatus/version'
require 'active_support/time'
require 'unirest'
require 'yaml'
require 'ostruct'
require 'trollop'
require 'forwardable'
require 'json'
require 'sentry-raven'
require 'pagerduty'
require 'time'
require 'socket'
require 'byebug'

class Upstreamstatus
  extend Forwardable

  def_delegators :@conf,
                 :status_check_url,
                 :sentry_dsn,
                 :pagerduty_api_url,
                 :pagerduty_service_id,
                 :pagerduty_api_key,
                 :pagerduty_rest_api_key

  attr_reader :conf

  def initialize
    @conf = OpenStruct.new load_conf

    return unless opts[:notify]

    %w(
      sentry_dsn
      pagerduty_api_key
      pagerduty_rest_api_key
      pagerduty_api_url
      pagerduty_service_id
    ).each do |key|
      fail "Config missing #{key}" unless conf[key]
    end

    Unirest.default_header 'Authorization',
                           "Token token=#{pagerduty_rest_api_key}"
    Unirest.default_header 'Content-type', 'application/json'
    Unirest.default_header 'Accept', 'application/vnd.pagerduty+json;version=2'

    Raven.configure do |config|
      config.dsn = sentry_dsn
      config.logger = logger
    end
  end

  def down_hosts
    current_status['servers']['server'].select { |s| s['status'] != 'up' }
  end

  def run
    clear_active_alerts

    exit 0 if down_hosts.empty?

    puts "Detected down hosts:\n"
    print_hosts down_hosts
    logger.info "Detected down hosts: #{down_hosts.to_json}"

    if opts[:notify]
      down_hosts.each do |host|
        notify(
          "Upstream host #{host['upstream']} listed as down",
          host
        )
      end
    end
    exit 1
  rescue Interrupt => e
    puts "Received #{e.class}"
    exit 99
  rescue SignalException => e
    logger.info "Received: #{e.signm} (#{e.signo})"
    exit 2
  rescue SystemExit => e
    exit e.status
  rescue Exception => e # Need to rescue "Exception" so that Sentry gets it
    Raven.capture_exception(e) if sentry_dsn
    logger.fatal e.message
    logger.fatal e.backtrace.join("\n")
    raise e
  end

  def current_status
    @current_status ||= begin
      return fake_response if opts[:simulate]

      r = Unirest.get status_check_url

      unless (200..299).include?(r.code)
        fail "Error code: #{r.code}\n" \
             "Headers: #{r.headers}" \
             "Body: #{r.body}"
      end

      r.body
    end
  end

  private

  def notify(msg, host)
    if active_alert?(host['upstream'])
      puts "Already an active alert. Not sending anything (message: #{msg})"
    else
      puts "Notifying PagerDuty (message: #{msg})"
      pagerduty.trigger(
        msg,
        incident_key: "upstreamstatus #{Socket.gethostname} #{host['upstream']}",
        client: Socket.gethostname,
        details: host
      )
    end
  end

  def active_alert?(host)
    active_alerts.find do |a|
      a['incident_key'] == "upstreamstatus #{Socket.gethostname} #{host['upstream']}"
    end
  end

  def active_alerts
    @active_alerts ||= active_alerts_paged.select do |a|
      a['incident_key'] =~ /^upstreamstatus #{Socket.gethostname} .*/
    end
  end

  def active_alerts_paged(offset = 0)
    r = Unirest.get(
      "#{pagerduty_api_url}/incidents?service_ids[]=#{pagerduty_service_id}&statuses[]=triggered&statuses[]=acknowledged&offset=#{offset}"
    )
    fail "Result: #{r.inspect}" unless (200..299).include?(r.code)
    return [] if r.body['total'].nil?

    pointer = r.body['limit'] + offset
    r.body['incidents'] + (pointer < r.body['total'] ? active_alerts_paged(pointer) : [])
  end

  def clear_active_alerts
    return unless opts[:notify]
    active_alerts.reject { |a| down_hosts_incident_keys.include? a['incident_key'] }.each do |a|
      puts "Resolving incident: #{a['incident_key']}"
      pagerduty.get_incident(a['incident_key']).resolve
    end
  end

  def down_hosts_incident_keys
    down_hosts.map { |host| "upstreamstatus #{Socket.gethostname} #{host['upstream']}" }
  end

  def logger
    @logger ||= Logger.new(conf['log']).tap { |l| l.progname = 'upstreamstatus' }
  end

  def pagerduty
    @pagerduty ||= Pagerduty.new pagerduty_api_key
  end

  def opts
    @opts ||= Trollop.options do
      opt :notify,
          'Notify alert service on failure',
          short: '-n',
          default: false
      opt :simulate,
          'Simulate a failed server',
          short: '-s',
          default: false
    end
  end

  def print_hosts(hosts)
    hosts.each do |host|
      host.each { |k, v| puts "#{k}: #{v}" }
      puts
    end
  end

  def load_conf
    conf_file = '/etc/upstreamstatus.yml'
    yaml_conf = File.exist?(conf_file) ? YAML.load_file(conf_file) : {}
    defaults.merge(yaml_conf)
  end

  def defaults
    { 'status_check_url' => 'http://localhost:8069/status?format=json' }
  end

  def fake_response
    {
      'servers' => {
        'total' => 2,
        'generation' => 99,
        'server' => [
          {
            'index' => 0,
            'upstream' => 'testupstream0',
            'name' => '10.0.0.1 =>8080',
            'status' => 'up',
            'rise' => 10_459,
            'fall' => 0,
            'type' => 'http',
            'port' => 0
          },
          {
            'index' => 1,
            'upstream' => 'testupstream1',
            'name' => '10.0.0.2 =>8080',
            'status' => 'down',
            'rise' => 10_029,
            'fall' => 0,
            'type' => 'http',
            'port' => 0
          },
          {
            'index' => 2,
            'upstream' => 'testupstream2',
            'name' => '10.0.0.2 =>8080',
            'status' => 'down',
            'rise' => 10_029,
            'fall' => 0,
            'type' => 'http',
            'port' => 0
          }
        ]
      }
    }
  end
end
