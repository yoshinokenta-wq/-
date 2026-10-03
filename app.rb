# frozen_string_literal: true

$stdout.sync = true
$stderr.sync = true

require 'bundler/setup'
require 'dotenv/load'
require 'logger'
require 'socket'
require 'sinatra/base'
require 'faye/websocket'
require 'puma'
require 'puma/server'
require_relative 'lib/gemini_bridge'

class LiveDemoApp < Sinatra::Base
  set :root, __dir__
  set :public_folder, File.expand_path('public', __dir__)
  set :static, true
  
  configure :development do
    set :host_authorization, { permitted_hosts: [] }
  end

  get '/' do
    send_file File.join(settings.public_folder, 'index.html')
  end

  get '/modes' do
    erb :modes rescue erb(:index)
  end

  # ★ 難易度選択画面（モードのパラメータを受け渡す処理を追加）
  get '/difficulty' do
    @mode = params[:mode] || 'practice'
    erb :difficulty rescue erb(:modes)
  end

  get '/interview' do
    @mode = params[:mode] || 'practice'
    @difficulty = params[:difficulty] || 'normal'
    erb :interview
  end

  get '/ws' do
    if Faye::WebSocket.websocket?(request.env)
      ws = Faye::WebSocket.new(request.env, nil, { ping: 20 })
      logger = Logger.new($stdout)
      logger.level = Logger::DEBUG
      bridge = GeminiBridge.new(ws, { logger: logger })

      if request.env['rack.hijack_io']
        begin
          request.env['rack.hijack_io'].setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        rescue => e
          # Ignore if socket options unsupported
        end
      end

      ws.on :open do |_event|
        puts "[LiveDemoApp] Browser client connected via WebSocket"
        bridge.start
      end

      ws.on :message do |event|
        bridge.handle_browser_message(event.data)
      end

      ws.on :close do |event|
        puts "[LiveDemoApp] Browser client disconnected (#{event.code}: #{event.reason})"
        bridge.close
        ws = nil
      end

      ws.rack_response
    else
      [400, { 'content-type' => 'text/plain' }, ['WebSocket connection required at /ws']]
    end
  end

  # Health check endpoint
  get '/health' do
    content_type :json
    { status: 'ok', time: Time.now.iso8601 }.to_json
  end
end

if __FILE__ == $PROGRAM_NAME
  port = (ENV['PORT'] || 4567).to_i
  host = ENV['HOST'] || '0.0.0.0'
  pid_file = File.expand_path('.server.pid', __dir__)

  File.write(pid_file, Process.pid.to_s)
  puts "[LiveDemoApp] Server PID: #{Process.pid} saved to #{pid_file}"

  at_exit do
    File.delete(pid_file) if File.exist?(pid_file)
    puts "[LiveDemoApp] Cleaned up PID file"
  end

  app = LiveDemoApp.new
  server = Puma::Server.new(app)
  server.add_tcp_listener(host, port)

  %i[INT TERM].each do |signal|
    Signal.trap(signal) do
      puts "\n[LiveDemoApp] Shutting down gracefully..."
      server.stop(true)
      exit 0
    end
  rescue ArgumentError
    # Some signals might not be supported on Windows
  end

  puts "========================================================="
  puts " Gemini 3.8 Live Demo Server started!"
  puts " URL: http://localhost:#{port}"
  puts " PID: #{Process.pid}"
  puts " Press Ctrl+C or run 'ruby kill_app.rb' to stop."
  puts "========================================================="

  begin
    server.run.join
  rescue Interrupt
    puts "\n[LiveDemoApp] Server stopped by user."
  end
end
