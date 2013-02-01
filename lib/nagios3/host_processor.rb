require 'net/http'
require 'json'

module Nagios3

  class HostProcessor
    def run
      perfdata, modems = parse_files
      load_to_database(perfdata, modems)
    end

    def send_noc
      perfdata, modems = get_from_database
      send_data(perfdata)
      decorate_modems!(modems)
      send_modems(modems)
      delete_old_data
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

    def load_to_database(perfdata,modems)
      perfdata.each do |p|
        if p[:id] && !(p[:id] =~ /^$/)
          run_sql(perfdata_sql(p))
        end
      end
      modems.each do |m|
        run_sql(modem_sql(m))
      end
    end

    def perfdata_sql(hash)
      str = <<-SQL
        insert into host_perfdata values (DEFAULT, #{hash[:time]},'#{hash[:id]}','#{hash[:host_name]}','#{hash[:status]}',
        #{hash[:duration]},'#{hash[:execution_time]}','#{hash[:latency]}','#{hash[:output]}','#{hash[:perfdata]}','#{DateTime.now.strftime("%Y-%m-%d %H:%M:%S")}')
SQL
    end

    def modem_sql(hash)
      str = <<-SQL
        insert into modem_perfdata values (DEFAULT, #{hash[:time]},'#{hash[:host_name]}','#{hash[:status]}',
        #{hash[:duration]},'#{hash[:execution_time]}','#{hash[:latency]}','#{hash[:output]}','#{hash[:perfdata]}','#{DateTime.now.strftime("%Y-%m-%d %H:%M:%S")}')
SQL

    end

    def perfdata_files
      d = Dir.new(File.dirname(Nagios3.host_perfdata_path))
      entries = d.entries
      entries.delete_if { |entry| !(entry =~ /^host-perfdata/) }
      entries.map! { |entry| File.join(d.path, entry) }
      entries.sort
    end

    def get_from_database
      host_sql = "select * from host_perfdata where sent_at is null"
      modem_sql = "select * from modem_perfdata where sent_at is null"
      result = [parse_sql_table(host_sql), parse_sql_table(modem_sql)]
    end

    def parse_sql_table(sql)
      tbl = run_sql(sql)
      rows = tbl.split("\n")[2..-2]
      columns = tbl.split("\n")[0].split("|").each{|c|c.strip!}
      columns[columns.index("id")] = "table_id"
      if columns.index("host_id")
        columns[columns.index("host_id")] = "id"
      end
      result = []
      rows.each do |r|
        row = {}
        r.split("|").each_with_index do |v, i|
          row[columns[i].to_sym] = v.strip
        end
        if r =~ /[\w\d]+/
          result << row
        end
      end
      result
    end

    def send_data(perfdata)
      perfdata.uniq!{|row|row[:table_id]}
      perfdata.in_groups_of(50, false) do |batch|
        push_request(Nagios3.host_perfdata_url, batch.to_json)
        mark_hosts(batch)
      end
    end

    def decorate_modems!(modems)
      modems.each do |modem_hash|
        cable_modem = CableModem.find_by_mac_address(modem_hash[:host_name].upcase, :include => :cmts)
        modem_hash[:id] = "modem"
        if cable_modem
          modem_hash[:cm_state] = cable_modem.status
          modem_hash[:ip_address] = cable_modem.ip_address
          modem_hash[:cmts_address] = cable_modem.cmts.try(:ip_address)
          modem_hash[:upstream_interface] = cable_modem.upstream_interface
          modem_hash[:downstream_interface] = cable_modem.downstream_interface
          modem_hash[:upstream_snr] = cable_modem.upstream_snr
          modem_hash[:upstream_power] = cable_modem.upstream_power
          modem_hash[:downstream_snr] = cable_modem.downstream_snr
          modem_hash[:downstream_power] = cable_modem.downstream_power
        end
      end
    end

    def send_modems(modems)
      modems.uniq!{|row|row[:table_id]}
      modems.in_groups_of(50, false) do |batch|
        push_request(Nagios3.modem_host_perfdata_url, batch.to_json)
        mark_modems(batch)
      end
    end

    def mark_hosts(hosts)
      if hosts.count > 0
        ids = hosts.inject([]){|sum, h| sum << h[:table_id]}.to_s.gsub!(/[\[\]]/,"")
        sql = "update host_perfdata set sent_at = '#{DateTime.now}' where id in (#{ids})"
        run_sql(sql)
      end
    end

    def mark_modems(modems)
      if modems.count > 0
        ids = modems.inject([]){|sum, h| sum << h[:table_id]}.to_s.gsub!(/[\[\]]/,"")
        sql = "update modem_perfdata set sent_at = '#{DateTime.now}' where id in (#{ids})"
        run_sql(sql)
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

    def delete_old_data
      sql = "delete from host_perfdata where created_at < '#{(DateTime.now-1.day).strftime("%Y-%m-%d %H:%M:%S")}'"
      run_sql(sql)
      sql = "delete from modem_perfdata where created_at < '#{(DateTime.now-1.day).strftime("%Y-%m-%d %H:%M:%S")}'"
      run_sql(sql)
    end

    def parse(line)
      if line =~ /^\[HOSTPERFDATA\]([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)\|([^\|]*)$/
        perf_hash = {
          :time => $1, :id => $2, :host_name => $3, :status => $4, :duration => $5,
          :execution_time => $6, :latency => $7, :output => $8, :perfdata => $9
        }
      end
    end

    def run_sql(sql)
      sql.gsub!("\n", " ")
      `/usr/local/pgsql/bin/psql probe_production ccisystems -c "#{sql}"`
    end

  end

end
