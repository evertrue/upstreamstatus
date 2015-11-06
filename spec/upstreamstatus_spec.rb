require 'spec_helper'

describe Upstreamstatus do
  it 'has a version number' do
    expect(Upstreamstatus::VERSION).not_to be nil
  end

  let(:some_working_server) do
    {
      'index' => 0,
      'upstream' => 'test-host',
      'name' => '10.0.0.1:8080',
      'status' => 'up',
      'rise' => 6855,
      'fall' => 0,
      'type' => 'http',
      'port' => 0
    }
  end

  let(:some_broken_server) do
    {
      'index' => 0,
      'upstream' => 'broken-host',
      'name' => '10.0.0.2:8080',
      'status' => 'down',
      'rise' => 6855,
      'fall' => 0,
      'type' => 'http',
      'port' => 0
    }
  end

  let(:us) do
    conf = {
      'pagerduty_api_key' => 'TEST_PD_KEY',
      'log' => '/var/log/upstreamstatus.log'
    }

    allow(YAML).to receive(:load_file).with(any_args).and_return(conf)

    us = Upstreamstatus.new

    allow(us).to receive(:pagerduty).and_return(
      object_double(
        'pagerduty',
        trigger: object_double(
          'PD trigger',
          incident_key: 'FAKE_INCIDENT_KEY'
        )
      )
    )

    allow(File).to receive(:write).and_call_original
    allow(File).to receive(:write).with(any_args).and_return 100

    allow(us).to receive(:sentry_dsn).and_return false
    allow(us).to receive(:opts).and_return(notify: true)

    us
  end

  context 'no hosts are down' do
    before(:each) do
      allow(Unirest).to receive(:get).with(any_args).and_return(
        object_double(
          'Unirest_HttpResponse',
          body: { 'servers' => { 'server' => [some_working_server] } },
          code: 200
        )
      )
    end

    it 'clear the active alerts file' do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/var/run/active_upstream_alert')
        .and_return true
      expect(File).to receive(:delete).with('/var/run/active_upstream_alert')
        .and_return 1
      begin
        us.run
      rescue SystemExit
      end
    end

    it 'exit with status 0' do
      allow(us).to receive(:clear_active_alerts!).and_return nil
      expect { us.run }.to raise_error do |error|
        expect(error).to be_a SystemExit
        expect(error.status).to eq(0)
      end
    end
  end

  context 'some hosts are down' do
    before(:each) do
      allow(Unirest).to receive(:get).with(any_args).and_return(
        object_double(
          'Unirest_HttpResponse',
          body: { 'servers' => { 'server' => [some_broken_server] } },
          code: 200
        )
      )
    end

    it 'print the list of down hosts' do
      allow(us).to receive_message_chain(:logger, :info)
      expect(us).to receive(:print_hosts).with([some_broken_server])
      begin
        us.run
      rescue SystemExit
      end
    end

    it 'logs about it' do
      expect(us).to receive_message_chain(:logger, :info).with(
        "Detected down hosts: #{[some_broken_server].to_json}"
      )
      allow(us).to receive(:print_hosts)
      begin
        us.run
      rescue SystemExit
      end
    end

    it 'notifies about it' do
      allow(us).to receive_message_chain(:logger, :info)
      allow(us).to receive(:print_hosts)
      expect(us).to receive(:notify).with(
        'One or more API upstream hosts listed as down',
        JSON.pretty_generate([some_broken_server])
      )
      begin
        us.run
      rescue SystemExit
      end
    end

    it 'exit with status 1' do
      allow(us).to receive_message_chain(:logger, :info)
      allow(us).to receive(:print_hosts)
      expect { us.run }.to raise_error do |error|
        expect(error).to be_a SystemExit
        expect(error.status).to eq(1)
      end
    end
  end
end
