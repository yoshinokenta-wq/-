# frozen_string_literal: true

require 'bundler/setup'
require 'dotenv/load'

pid_file = File.expand_path('.server.pid', __dir__)
port = (ENV['PORT'] || 4567).to_i

killed = false

# 1. Try to kill via .server.pid
if File.exist?(pid_file)
  pid = File.read(pid_file).strip.to_i
  if pid > 0
    puts "[kill_app] Found PID file with PID: #{pid}"
    begin
      if Gem.win_platform?
        # On Windows, taskkill is the most reliable way to terminate process and its children
        system("taskkill /F /PID #{pid} >NUL 2>&1")
      else
        Process.kill('TERM', pid)
      end
      puts "[kill_app] Sent termination signal to process #{pid}."
      killed = true
    rescue => e
      puts "[kill_app] Error sending signal to PID #{pid}: #{e.message}"
    end
  end
  File.delete(pid_file) if File.exist?(pid_file)
end

# 2. Check if port is still occupied (Windows fallback)
if Gem.win_platform?
  begin
    output = `netstat -ano | findstr :#{port}`
    pids = output.scan(/LISTENING\s+(\d+)/).flatten.uniq
    pids.each do |p|
      pid = p.to_i
      if pid > 0 && pid != Process.pid
        puts "[kill_app] Found listening process on port #{port} with PID: #{pid}. Terminating..."
        system("taskkill /F /PID #{pid} >NUL 2>&1")
        killed = true
      end
    end
  rescue => e
    puts "[kill_app] Error checking port occupancy: #{e.message}"
  end
end

if killed
  puts "[kill_app] Server stopped successfully."
else
  puts "[kill_app] No running server process was found on port #{port}."
end
