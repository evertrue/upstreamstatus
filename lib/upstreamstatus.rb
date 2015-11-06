require 'upstreamstatus/version'
require 'unirest'
require 'yaml'
require 'ostruct'
require 'trollop'
require 'forwardable'
require 'json'
require 'sentry-raven'

class Upstreamstatus
  extend Forwardable

  def_delegators :@conf,
                 :status_check_url,
                 :sentry_dsn,
                 :pagerduty_api_key

  attr_reader :conf

  def initialize
    @conf = OpenStruct.new load_conf

    return unless opts[:notify] && sentry_dsn
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

    print_hosts down_hosts
    logger.notice "Detected down hosts: #{down_hosts.to_json}"

    if opts[:notify]
      puts 'Sending notifications'
      notify(
        'One or more API upstream hosts listed as down',
        JSON.pretty_generate(down_hosts)
      )
    end
    exit 1
  end

  def current_status
    r = Unirest.get status_check_url

    unless (200..299).include?(r.code)
      fail "Error code: #{r.code}\n" \
           "Headers: #{r.headers}" \
           "Body: #{r.body}"
    end

    r.body
  end

  private

  def clear_active_alerts!
    return unless File.exist? '/var/run/active_upstream_alert'
    File.delete('/var/run/active_upstream_alert')
  end

  def logger
    @logger ||= Logger.new(conf['log']).tap { |l| l.progname = 'upstreamstatus' }
  end

  def pagerduty
    @pagerduty ||= Pagerduty.new pagerduty_api_key
  end

  def notify(msg, details)
    unless active_alert?(msg)
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

    Raven.capture_exception(e) if sentry_dsn
  end

  def active_alert?(msg)
    File.exist?('/var/run/active_upstream_alert') &&
      (Time.now - File.ctime('/var/run/active_upstream_alert')) < 3600 &&
      JSON.parse(File.read('/var/run/active_upstream_alert'))['msg'] == msg
  end

  def opts
    @opts ||= Trollop.options do
      opt :notify,
          'Notify alert service on failure',
          short: '-n',
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
