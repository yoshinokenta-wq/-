# frozen_string_literal: true

require 'bundler/setup'
require 'net/http'
require 'uri'
require 'json'
require_relative 'app'
require_relative 'lib/gemini_bridge'

class TestRunner
  def initialize
    @passed = 0
    @failed = 0
  end

  def assert(condition, description)
    if condition
      puts "  \e[32m[PASS]\e[0m #{description}"
      @passed += 1
    else
      puts "  \e[31m[FAIL]\e[0m #{description}"
      @failed += 1
    end
  end

  def report
    puts "\n--------------------------------------------------"
    puts " Test Summary: #{@passed} passed, #{@failed} failed"
    puts "--------------------------------------------------"
    exit(@failed.zero? ? 0 : 1)
  end
end

runner = TestRunner.new
puts "=================================================="
puts " Running Gemini 3.8 Live Demo Tests"
puts "=================================================="

# Test Suite 1: GeminiBridge Unit Tests
puts "\n[Suite 1] GeminiBridge Logic & Payload Tests"

class MockBrowserWs
  attr_reader :sent_messages
  def initialize
    @sent_messages = []
  end
  def send(msg)
    @sent_messages << msg
  end
end

mock_ws = MockBrowserWs.new
bridge = GeminiBridge.new(mock_ws, {
  model: 'gemini-3.8-live',
  voice: 'Puck',
  mock_mode: true
})

# Test setup payload
setup_payload = bridge.build_setup_payload
runner.assert(
  setup_payload[:setup][:model] == 'models/gemini-3.8-live',
  "build_setup_payload formats model to 'models/gemini-3.8-live'"
)
runner.assert(
  setup_payload[:setup][:generationConfig][:responseModalities] == ['AUDIO'],
  "build_setup_payload configures responseModalities: ['AUDIO']"
)
runner.assert(
  setup_payload[:setup][:generationConfig][:speechConfig][:voiceConfig][:prebuiltVoiceConfig][:voiceName] == 'Puck',
  "build_setup_payload configures voiceName: 'Puck'"
)
runner.assert(
  setup_payload[:setup].key?(:inputAudioTranscription),
  "build_setup_payload enables inputAudioTranscription for user speech recognition"
)
runner.assert(
  setup_payload[:setup].key?(:outputAudioTranscription),
  "build_setup_payload enables outputAudioTranscription for model speech"
)

# Test initial trigger payload
trigger_payload = bridge.build_initial_trigger_payload
runner.assert(
  trigger_payload[:clientContent][:turnComplete] == true,
  "build_initial_trigger_payload has turnComplete: true for starting the first turn"
)
runner.assert(
  trigger_payload[:clientContent][:turns].first[:role] == 'user',
  "build_initial_trigger_payload starts with user prompt turn"
)

# Test mock session starts and notifies browser
bridge.start
runner.assert(
  mock_ws.sent_messages.any? { |m| m.include?('setup_complete') },
  "bridge.start notifies browser with setup_complete"
)

# Test browser message handling: turn_complete
class MockGeminiClient
  attr_reader :sent_messages
  def initialize; @sent_messages = []; end
  def send(data); @sent_messages << data; end
  def close; end
end

bridge.instance_variable_set(:@gemini_client, MockGeminiClient.new)
bridge.instance_variable_set(:@is_open, true)

# Test browser message handling: turn_complete
bridge.instance_variable_set(:@setup_completed, true)
bridge.handle_browser_message({ type: 'turn_complete' }.to_json)
sent_to_gemini = bridge.gemini_client.sent_messages.last
parsed_sent = JSON.parse(sent_to_gemini)
runner.assert(
  parsed_sent.dig('realtimeInput', 'activityEnd') != nil,
  "handle_browser_message('turn_complete') sends realtimeInput with activityEnd to signal end of user turn"
)

# Test browser message handling: text
bridge.handle_browser_message({ type: 'text', text: 'こんにちは' }.to_json)
text_sent = JSON.parse(bridge.gemini_client.sent_messages.last)
runner.assert(
  text_sent.dig('clientContent', 'turns', 0, 'parts', 0, 'text') == 'こんにちは',
  "handle_browser_message('text') sends text prompt in clientContent to Gemini"
)

# Test browser message handling: audio
dummy_base64 = "UklGRg=="
bridge.handle_browser_message({ type: 'audio', data: dummy_base64, mimeType: 'audio/pcm;rate=48000' }.to_json)
audio_sent = JSON.parse(bridge.gemini_client.sent_messages.last)
runner.assert(
  audio_sent.dig('realtimeInput', 'audio', 'data') == dummy_base64,
  "handle_browser_message('audio') forwards PCM audio chunk to Gemini realtimeInput"
)
runner.assert(
  audio_sent.dig('realtimeInput', 'audio', 'mimeType') == 'audio/pcm;rate=48000',
  "handle_browser_message('audio') preserves client mimeType (e.g. rate=48000)"
)

# Test Suite 2: Rack Direct Dispatch Tests (No extra gems needed)
puts "\n[Suite 2] Sinatra Rack Direct Dispatch Tests"
rack_app = LiveDemoApp.new

# GET /health
env_health = {
  'REQUEST_METHOD' => 'GET',
  'PATH_INFO' => '/health',
  'rack.input' => StringIO.new
}
status, _headers, body = rack_app.call(env_health)
body_str = body.respond_to?(:join) ? body.join : body.to_s
runner.assert(status == 200, "GET /health returns 200 OK")
health_data = JSON.parse(body_str)
runner.assert(health_data['status'] == 'ok', "GET /health returns status: 'ok'")

# GET /
env_root = {
  'REQUEST_METHOD' => 'GET',
  'PATH_INFO' => '/',
  'rack.input' => StringIO.new
}
status, _headers, body = rack_app.call(env_root)
runner.assert(status == 200, "GET / returns 200 OK (index.html)")

# Test Suite 3: Running Server E2E Tests (http://localhost:4567)
puts "\n[Suite 3] Running Server E2E Tests (http://localhost:4567)"
port = (ENV['PORT'] || 4567).to_i
begin
  uri = URI("http://localhost:#{port}/health")
  res = Net::HTTP.get_response(uri)
  if res.is_a?(Net::HTTPSuccess)
    runner.assert(true, "Server is actively listening on port #{port}")
    runner.assert(JSON.parse(res.body)['status'] == 'ok', "Live server responded to /health check")

    # Also test GET /
    root_res = Net::HTTP.get_response(URI("http://localhost:#{port}/"))
    runner.assert(root_res.is_a?(Net::HTTPSuccess), "Live server responded with 200 OK for GET /")
    runner.assert(root_res.body.include?('src="/images/Culcture.png"'), "Live server serves the title image on the top page")
  end
rescue Errno::ECONNREFUSED
  puts "  \e[33m[INFO]\e[0m Server is not currently running on port #{port} (Skipping live HTTP E2E; start with 'ruby app.rb')"
rescue => e
  puts "  \e[33m[INFO]\e[0m Live server check error: #{e.message}"
end

runner.report
