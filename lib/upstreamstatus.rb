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

    Raven.configure do |config|
      config.dsn = sentry_dsn
      config.logger = logger
    end
  end

  def run
    down_hosts =
      current_status['servers']['server'].select { |s| s['status'] != 'up' }

    if down_hosts.empty?
      clear_active_alerts!
      exit 0
    end

    puts "Detected down hosts:\n"
    print_hosts down_hosts
    logger.info "Detected down hosts: #{down_hosts.to_json}"

    if opts[:notify]
      notify(
        'One or more API upstream hosts listed as down',
        JSON.pretty_generate(down_hosts)
      )
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
    return fake_response if opts[:simulate]

    r = Unirest.get status_check_url

    unless (200..299).include?(r.code)
      fail "Error code: #{r.code}\n" \
           "Headers: #{r.headers}" \
           "Body: #{r.body}"
    end

    r.body
  end

  private

  def pd_incidents
    @pd_incidents ||= begin
      r = Unirest.get(
        "#{pagerduty_api_url}/incidents",
        parameters: { service: pagerduty_service_id }
      )
      fail "Result: #{r.inspect}" unless (200..299).include?(r.code)
      r.body['incidents']
    end
  end

  def fake_response
    {
      'servers' => {
        'total' => 2,
        'generation' => 99,
        'server' => [
          {
            'index' => 0,
            'upstream' => 'testupstream',
            'name' => '10.0.0.1 =>8080',
            'status' => 'up',
            'rise' => 10_459,
            'fall' => 0,
            'type' => 'http',
            'port' => 0
          },
          {
            'index' => 1,
            'upstream' => 'testupstream',
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

  def clear_active_alerts!
    return unless opts[:notify]
    pd_incidents.each do |i|
      resolve_incident i['incident_key'] unless i['status'] == 'resolved'
    end
  end

  def resolve_incident(incident_key)
    puts "Resolving incident: #{incident_key}"
    pagerduty.get_incident(incident_key).resolve
  end

  def logger
    @logger ||= Logger.new(conf['log']).tap { |l| l.progname = 'upstreamstatus' }
  end

  def pagerduty
    @pagerduty ||= Pagerduty.new pagerduty_api_key
  end

  def notify(msg, details)
    if active_alert?(msg)
      puts "Already an active alert. Not sending anything (message: #{msg})"
    else
      puts "Notifying PagerDuty (message: #{msg})"
      pd = pagerduty.trigger(
        msg,
        client: ENV['hostname'],
        details: details
      )

      # You may have noticed that this will overwrite any previously active
      # alerts, regardless of whether they are the "same" alert. This is a known
      # limitation.

      File.write(
        '/var/run/active_upstream_alert',
        {
          'Incident Key' => pd.incident_key,
          'Message' => msg,
          'Details' => details
        }.to_json
      )
    end
  end

  def active_alert?(msg)
    pd_incidents.find do |incident|
      incident['status'] != 'resolved' &&
        incident['trigger_summary_data']['description'] == msg
    end
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
end
