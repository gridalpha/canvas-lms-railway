# Health server for the delayed_jobs service.
#
# The jobs role serves no HTTP of its own, so without this Railway has nothing to
# probe and a crash-looping worker reads SUCCESS forever. Two real signals:
#
#   * the delayed_job pool is alive. The entrypoint backgrounds this script and
#     then execs the pool into its own PID, so this process' parent *is* the pool.
#     When the pool dies we are reparented to PID 1 and the check fails.
#   * Postgres is reachable, which is the dependency the worker cannot run without.
#
# The database probe runs on a background thread and the request handler serves the
# cached answer — a connect attempt can outlast the prober's own timeout.

require "socket"

PORT = Integer(ENV.fetch("PORT", "3000"))
DB_HOST = ENV["CANVAS_DB_HOST"].to_s.empty? ? "postgres.railway.internal" : ENV["CANVAS_DB_HOST"]
DB_PORT = Integer(ENV.fetch("CANVAS_DB_PORT", "5432"))

$db_ok = true

Thread.new do
  loop do
    begin
      Socket.tcp(DB_HOST, DB_PORT, connect_timeout: 5, &:close)
      $db_ok = true
    rescue StandardError => e
      $db_ok = false
      warn "[jobs_health] database unreachable: #{e.class}: #{e.message}"
    end
    sleep 15
  end
end

def pool_alive?
  Process.ppid > 1
end

def read_request(conn)
  request_line = conn.gets.to_s
  while (line = conn.gets)
    break if line.strip.empty?
  end
  request_line
end

server = TCPServer.new("0.0.0.0", PORT)
warn "[jobs_health] listening on 0.0.0.0:#{PORT}"

loop do
  begin
    client = server.accept
  rescue StandardError
    next
  end

  Thread.new(client) do |conn|
    begin
      request_line = read_request(conn)
      alive = pool_alive?
      healthy = alive && $db_ok
      status = healthy ? "200 OK" : "503 Service Unavailable"
      body = "delayed_jobs pool=#{alive ? 'up' : 'down'} database=#{$db_ok ? 'up' : 'down'}\n"

      conn.print "HTTP/1.1 #{status}\r\n"
      conn.print "Content-Type: text/plain\r\n"
      conn.print "Content-Length: #{body.bytesize}\r\n"
      conn.print "Connection: close\r\n\r\n"
      conn.print body unless request_line.start_with?("HEAD ")
    rescue StandardError
      # a dropped client must never take the health server down
    ensure
      begin
        conn.close
      rescue StandardError
        nil
      end
    end
  end
end
