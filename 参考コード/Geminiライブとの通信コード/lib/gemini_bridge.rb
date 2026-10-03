# frozen_string_literal: true

require 'json'
require 'websocket-client-simple'
require 'logger'
require 'eventmachine'

class GeminiBridge
  GEMINI_HOST = 'generativelanguage.googleapis.com'
  GEMINI_PATH = '/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'
  DEFAULT_MODEL = 'models/gemini-3.8-live'
  DEFAULT_VOICE = 'Puck'
  DEFAULT_SYSTEM_PROMPT = 'あなたは親切でフレンドリーなAIアシスタントです。会話のテンポを最重要視し、1〜2文程度の短く簡潔で自然な日本語で素早く返答してください。'

  attr_reader :browser_ws, :gemini_client, :is_open, :setup_completed

  def initialize(browser_ws, options = {})
    @browser_ws = browser_ws
    @api_key = options[:api_key] || ENV['GEMINI_API_KEY']
    @model = format_model_name(options[:model] || ENV['GEMINI_MODEL'] || DEFAULT_MODEL)
    @voice = options[:voice] || ENV['GEMINI_VOICE'] || DEFAULT_VOICE
    @system_prompt = options[:system_prompt] || DEFAULT_SYSTEM_PROMPT
    @logger = options[:logger] || Logger.new($stdout)
    @gemini_client = nil
    @is_open = false
    @setup_completed = false
    @activity_started = false
    @audio_chunks_sent = 0
    @mock_mode = options[:mock_mode] || false
  end

  def start
    if @mock_mode || @api_key.nil? || @api_key.strip.empty?
      @logger.warn('[GeminiBridge] No GEMINI_API_KEY provided or mock_mode enabled. Operating in mock mode.')
      start_mock_session
      return
    end

    connect_to_gemini
  end

  def handle_browser_message(raw_data)
    begin
      data = JSON.parse(raw_data)
    rescue JSON::ParserError => e
      @logger.error("[GeminiBridge] JSON parse error from browser: #{e.message}")
      return
    end

    case data['type']
    when 'audio'
      # Audio chunk from browser microphone (PCM, base64 encoded)
      mime_type = data['mimeType'] || 'audio/pcm;rate=16000'
      send_audio_to_gemini(data['data'], mime_type)
    when 'turn_complete'
      # Silence detected on browser; client signals turn completion
      send_turn_complete_to_gemini
    when 'text'
      # Optional text input from browser
      send_text_to_gemini(data['text'])
    else
      @logger.warn("[GeminiBridge] Unknown message type from browser: #{data['type']}")
    end
  end

  def send_audio_to_gemini(base64_audio, mime_type = 'audio/pcm;rate=16000')
    # Must wait until setupComplete is received before sending any realtimeInput!
    return unless @is_open && @gemini_client && @setup_completed

    @audio_chunks_sent = (@audio_chunks_sent || 0) + 1

    # Send activityStart before the first audio chunk of each user turn
    unless @activity_started
      @activity_started = true
      @logger.info('[GeminiBridge] Sending activityStart for new user turn')
      safe_send({ realtimeInput: { activityStart: {} } }.to_json)
    end

    if @audio_chunks_sent == 1 || (@audio_chunks_sent % 40).zero?
      @logger.info("[GeminiBridge] Streaming audio to Gemini... (chunk ##{@audio_chunks_sent}, mime: #{mime_type}, bytes: #{base64_audio.length})")
    end

    payload = {
      realtimeInput: {
        audio: {
          mimeType: mime_type,
          data: base64_audio
        }
      }
    }
    safe_send(payload.to_json)
  end

  def send_turn_complete_to_gemini
    return unless @is_open && @gemini_client && @setup_completed

    @logger.info('[GeminiBridge] Browser detected silence; sending activityEnd to signal end of user speech')
    @activity_started = false  # Reset so next speech segment gets activityStart
    @audio_chunks_sent = 0    # Reset chunk counter for next turn
    safe_send({ realtimeInput: { activityEnd: {} } }.to_json)
  end

  def send_text_to_gemini(text)
    return unless @is_open && @gemini_client

    payload = {
      clientContent: {
        turns: [
          {
            role: 'user',
            parts: [{ text: text }]
          }
        ],
        turnComplete: true
      }
    }
    safe_send(payload.to_json)
  end

  def close
    @is_open = false
    if @gemini_client
      begin
        @gemini_client.close
      rescue => e
        @logger.error("[GeminiBridge] Error closing gemini client: #{e.message}")
      end
      @gemini_client = nil
    end
  end

  # Helper to construct setup payload
  def build_setup_payload
    {
      setup: {
        model: @model,
        generationConfig: {
          responseModalities: ['AUDIO'],
          speechConfig: {
            voiceConfig: {
              prebuiltVoiceConfig: {
                voiceName: @voice
              }
            },
            languageCode: 'ja-JP'
          }
        },
        realtimeInputConfig: {
          automaticActivityDetection: {
            disabled: true  # We handle VAD client-side, using activityStart/activityEnd
          },
          activityHandling: 'START_OF_ACTIVITY_INTERRUPTS'
        },
        inputAudioTranscription: {},
        outputAudioTranscription: {},
        systemInstruction: {
          parts: [
            { text: @system_prompt }
          ]
        }
      }
    }
  end

  # Helper to construct initial greeting trigger (first turn initiated by Gemini)
  def build_initial_trigger_payload
    {
      clientContent: {
        turns: [
          {
            role: 'user',
            parts: [
              { text: 'こんにちは！会話を始めてください。' }
            ]
          }
        ],
        turnComplete: true
      }
    }
  end

  # Public callback handlers called by WebSocket client
  def on_gemini_open
    @is_open = true
    @logger.info('[GeminiBridge] Gemini Live WebSocket opened. Sending setup...')
    safe_send(build_setup_payload.to_json)
    notify_browser({ type: 'status', message: 'Gemini Live に接続しました。初期化中...' })
  end

  def on_gemini_message(raw_data)
    @logger.debug("[GeminiBridge] <<< RAW: #{raw_data[0..400]}")
    begin
      parsed = JSON.parse(raw_data)
    rescue JSON::ParserError
      # Gemini sometimes sends plain-text error messages (not JSON)
      @logger.error("[GeminiBridge] Non-JSON message from Gemini: #{raw_data[0..300]}")
      notify_browser({ type: 'error', message: "Gemini APIエラー: #{raw_data[0..200]}" })
      return
    end

    # Handle top-level errors from Gemini API
    if parsed.key?('error')
      err_msg = parsed['error']['message'] || parsed['error'].to_s
      @logger.error("[GeminiBridge] Error from Gemini API: #{err_msg}")
      notify_browser({ type: 'error', message: "Gemini APIエラー: #{err_msg}" })
      return
    end

    # Handle setupComplete
    if parsed.key?('setupComplete')
      @setup_completed = true
      @logger.info('[GeminiBridge] Setup complete received. Triggering initial turn from Gemini...')
      notify_browser({
        type: 'setup_complete',
        message: 'Geminiの初期化が完了しました。最初の挨拶を開始します...'
      })

      # Trigger Gemini to start the first turn automatically
      safe_send(build_initial_trigger_payload.to_json)
      return
    end

    # Handle serverContent (modelTurn, interrupted, turnComplete, transcriptions)
    if parsed.key?('serverContent')
      server_content = parsed['serverContent']
      model_turn = server_content['modelTurn']
      interrupted = server_content['interrupted'] || false
      turn_complete = server_content['turnComplete'] || false

      # Extract real-time transcriptions (both final and interim)
      user_transcript = server_content.dig('inputTranscription', 'text') ||
                        server_content.dig('interimInputTranscription', 'text')
      model_transcript = server_content.dig('outputTranscription', 'text')

      if user_transcript && !user_transcript.strip.empty?
        @logger.info("[GeminiBridge] >>> User Speech Transcribed: '#{user_transcript}'")
      end

      audio_parts = []
      text_parts = []

      if model_turn && model_turn['parts']
        model_turn['parts'].each do |part|
          text_parts << part['text'] if part.key?('text')
          if part.key?('inlineData') && part['inlineData']['data']
            audio_parts << {
              mimeType: part['inlineData']['mimeType'],
              data: part['inlineData']['data']
            }
          end
        end
      end

      response_text = text_parts.join('')
      response_text = model_transcript if response_text.empty? && model_transcript

      if !audio_parts.empty? || !response_text.empty? || turn_complete
        @logger.info("[GeminiBridge] Gemini responding: audio_chunks=#{audio_parts.length}, text='#{response_text}', turn_complete=#{turn_complete}")
      end

      notify_browser({
        type: 'gemini_response',
        audio_chunks: audio_parts,
        text: response_text,
        user_transcript: user_transcript,
        interrupted: interrupted,
        turn_complete: turn_complete
      })
    end
  end

  def on_gemini_close(e)
    @is_open = false
    @logger.info("[GeminiBridge] Gemini WebSocket closed: #{e}")
    notify_browser({ type: 'status', message: 'Gemini との接続が切断されました' })
  end

  def on_gemini_error(e)
    @logger.error("[GeminiBridge] Gemini WebSocket error: #{e}")
    notify_browser({ type: 'error', message: "Gemini エラー: #{e}" })
  end

  private

  def format_model_name(model)
    model = model.to_s.strip
    if model.start_with?('models/')
      model
    else
      "models/#{model}"
    end
  end

  def connect_to_gemini
    url = "wss://#{GEMINI_HOST}#{GEMINI_PATH}?key=#{@api_key}"
    @logger.info("[GeminiBridge] Connecting to Gemini Live API: #{@model}")

    bridge = self

    begin
      @gemini_client = WebSocket::Client::Simple.connect(url)
    rescue => e
      @logger.error("[GeminiBridge] Failed to connect to Gemini Live: #{e.message}")
      notify_browser({ type: 'error', message: "Gemini接続エラー: #{e.message}" })
      return
    end

    @gemini_client.on :open do
      bridge.on_gemini_open
    end

    @gemini_client.on :message do |msg|
      bridge.on_gemini_message(msg.data)
    end

    @gemini_client.on :close do |e|
      bridge.on_gemini_close(e)
    end

    @gemini_client.on :error do |e|
      bridge.on_gemini_error(e)
    end
  end

  def safe_send(str)
    return unless @gemini_client
    begin
      @gemini_client.send(str)
    rescue => e
      @logger.error("[GeminiBridge] Error sending to Gemini: #{e.message}")
    end
  end

  def notify_browser(payload)
    return unless @browser_ws

    msg = payload.to_json
    if defined?(EventMachine) && EventMachine.reactor_running?
      EventMachine.schedule do
        begin
          @browser_ws.send(msg)
        rescue => e
          @logger.error("[GeminiBridge] Error sending to browser in EM: #{e.message}")
        end
      end
    else
      begin
        @browser_ws.send(msg)
      rescue => e
        @logger.error("[GeminiBridge] Error sending to browser: #{e.message}")
      end
    end
  end

  # Mock mode implementation for testing when GEMINI_API_KEY is not set
  def start_mock_session
    @is_open = true
    @setup_completed = true
    notify_browser({
      type: 'setup_complete',
      message: '[MOCK] Gemini初期化完了。モックモードで動作中'
    })
    # Send mock greeting
    Thread.new do
      sleep 0.5
      notify_browser({
        type: 'gemini_response',
        audio_chunks: [],
        text: 'こんにちは！モックモードです。何か話しかけてください。',
        interrupted: false,
        turn_complete: true
      })
    end
  end
end
