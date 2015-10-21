require 'upstreamstatus/version'
require 'unirest'
require 'yaml'
require 'ostruct'
require 'forwardable'

class Upstreamstatus
  extend Forwardable

  def_delegators :@conf,
                 :status_check_url

  def initialize
    @conf = OpenStruct.new load_conf
  end

  def run
    down_hosts =
      current_status['servers']['server'].select { |s| s['status'] != 'up' }

    exit 0 if down_hosts.empty?
    print_hosts down_hosts
    exit 1
  end

  private

  def print_hosts(hosts)
    hosts.each do |host|
      host.each { |k, v| puts "#{k}: #{v}" }
      puts
    end
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

  def load_conf
    conf_file = '/etc/upstreamstatus.yml'
    yaml_conf = File.exist?(conf_file) ? YAML.load_file(conf_file) : {}
    defaults.merge(yaml_conf)
  end

  def defaults
    {
      'status_check_url' => 'http://localhost:8069/status?format=json'
    }
  end
end
