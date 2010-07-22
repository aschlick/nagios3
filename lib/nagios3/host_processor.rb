require 'net/http'
require 'json'

module Nagios3
  
  class HostProcessor
    def run
      perfdata, modems = parse_files
      send_data(perfdata)
      decorate_modems!(modems)
      send_modems(modems)
    end
    
  private
    def parse_files
      entries, perfdata, modems = perfdata_files, [], []
      entries.each do |entry|
        lines = File.readlines(entry)
        File.open(entry, "w") # clear file
        lines.each do |line|
          parsed_perfdata_line = parse(line)
          if parsed_perfdata_line[:id] == "modem"
            modems << parsed_perfdata_line
          else
            perfdata << parsed_perfdata_line
          end
        end
      end
      [perfdata, modems]
    end
    
    def perfdata_files
      d = Dir.new(File.dirname(Nagios3.host_perfdata_path))
      entries = d.entries
      entries.delete_if { |entry| !(entry =~ /^host-perfdata/) }
      entries.map! { |entry| File.join(d.path, entry) }
      entries.sort
    end
    
    def send_data(perfdata)
      perfdata.in_groups_of(50, false) do |batch|
        push_request(Nagios3.host_perfdata_url, batch.to_json)
      end
    end
    
    def decorate_modems!(modems)
      modems.each do |modem_hash|
        cable_modem = CableModem.find_by_mac_address(modem_hash[:host_name].upcase, :include => :cmts)
        if cable_modem
          modem_hash[:cm_state] = cable_modem.status
          modem_hash[:ip_address] = cable_modem.ip_address
          modem_hash[:cmts_address] = cable_modem.cmts.ip_address
          modem_hash[:cmts_interface] = cable_modem.cmts_interface
          modem_hash[:upstream_snr] = cable_modem.upstream_snr
        end
      end
    end
    
    def send_modems(modems)
      modems.in_groups_of(50, false) do |batch|
        push_request(Nagios3.modem_host_perfdata_url, batch.to_json)
      end
    end
    
    def push_request(url, body)
      uri = URI.parse(url)
      headers = {
        'Content-Type' => 'application/json',
        'Content-Length' => body.size.to_s
      }
      request = Net::HTTP::Post.new(uri.path, headers)
      http = Net::HTTP.new(uri.host, uri.port)
      timeout(5) do
        response = http.request(request, body)
      end
    end
    
    def parse(line)
      if line =~ /^\[HOSTPERFDATA\]([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)$/
        perf_hash = {
          :time => $1, :id => $2, :host_name => $3, :status => $4, :duration => $5, 
          :execution_time => $6, :latency => $7, :output => $8, :perfdata => $9
        }
      end
    end
  
  end
  
end
