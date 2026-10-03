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
  
  def self.load_system_prompt
    ['prompts/evaluation.txt', 'prompts/evaluation.tet'].each do |path|
      return File.read(path, encoding: 'utf-8').strip if File.exist?(path)
    end
    'あなたは企業の採用面接官です。応募者に対する模擬面接を行ってください。実際の面接らしく、まずは自己紹介や志望動機などの質問を1つずつ投げかけてください。会話のテンポを最重要視し、1〜2文程度の短く簡潔で自然な日本語で話してください。'
  end

  attr_reader :browser_ws, :gemini_client, :is_open, :setup_completed

  def initialize(browser_ws, options = {})
    @browser_ws = browser_ws
    @api_key = options[:api_key] || ENV['GEMINI_API_KEY']
    @model = format_model_name(options[:model] || ENV['GEMINI_MODEL'] || DEFAULT_MODEL)
    @voice = options[:voice] || ENV['GEMINI_VOICE'] || DEFAULT_VOICE
    @system_prompt = options[:system_prompt] || ENV['GEMINI_SYSTEM_PROMPT'] || self.class.load_system_prompt
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
      mime_type = data['mimeType'] || 'audio/pcm;rate=16000'
      send_audio_to_gemini(data['data'], mime_type)
    when 'turn_complete'
      send_turn_complete_to_gemini
    when 'text'
      send_text_to_gemini(data['text'])
    else
      @logger.warn("[GeminiBridge] Unknown message type from browser: #{data['type']}")
    end
  end

  def send_audio_to_gemini(base64_audio, mime_type = 'audio/pcm;rate=16000')
    return unless @is_open && @gemini_client && @setup_completed

    @audio_chunks_sent = (@audio_chunks_sent || 0) + 1

    if @audio_chunks_sent == 1 || (@audio_chunks_sent % 40).zero?
      @logger.info("[GeminiBridge] Streaming audio to Gemini... (chunk ##{@audio_chunks_sent}, mime: #{mime_type}, bytes: #{base64_audio.length})")
    end

    # ▼ 【修正点】Gemini API仕様に合わせて mediaChunks 配列に変更
    payload = {
      realtimeInput: {
        mediaChunks: [
          {
            mimeType: mime_type,
            data: base64_audio
          }
        ]
      }
    }
    safe_send(payload.to_json)
  end

  def send_turn_complete_to_gemini
    return unless @is_open && @gemini_client && @setup_completed

    @logger.info('[GeminiBridge] Browser detected silence; signaling end of turn to Gemini')
    @audio_chunks_sent = 0 
    
    # 音声入力の区切りを伝えるために clientContent でターン完了を通知
    payload = {
      clientContent: {
        turnComplete: true
      }
    }
    safe_send(payload.to_json)
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

  def build_initial_trigger_payload
    {
      clientContent: {
        turns: [
          {
            role: 'user',
            parts: [
              { text: 'それでは模擬面接を始めます。最初の質問をしてください。' }
            ]
          }
        ],
        turnComplete: true
      }
    }
  end

  def on_gemini_open
    @is_open = true
    @logger.info('[GeminiBridge] Gemini Live WebSocket opened. Sending setup...')
    safe_send(build_setup_payload.to_json)
    notify_browser({ type: 'status', message: '面接の準備をしています...' })
  end

  def on_gemini_message(raw_data)
    @logger.debug("[GeminiBridge] <<< RAW: #{raw_data[0..400]}")
    begin
      parsed = JSON.parse(raw_data)
    rescue JSON::ParserError
      @logger.error("[GeminiBridge] Non-JSON message from Gemini: #{raw_data[0..300]}")
      notify_browser({ type: 'error', message: "Gemini APIエラー: #{raw_data[0..200]}" })
      return
    end

    if parsed.key?('error')
      err_msg = parsed['error']['message'] || parsed['error'].to_s
      @logger.error("[GeminiBridge] Error from Gemini API: #{err_msg}")
      notify_browser({ type: 'error', message: "Gemini APIエラー: #{err_msg}" })
      return
    end

    if parsed.key?('setupComplete')
      @setup_completed = true
      @logger.info('[GeminiBridge] Setup complete received. Triggering initial turn from Gemini...')
      notify_browser({
        type: 'setup_complete',
        message: '面接官が接続しました。まもなく質問が始まります...'
      })

      safe_send(build_initial_trigger_payload.to_json)
      return
    end

    if parsed.key?('serverContent')
      server_content = parsed['serverContent']
      model_turn = server_content['modelTurn']
      interrupted = server_content['interrupted'] || false
      turn_complete = server_content['turnComplete'] || false

      user_transcript = server_content.dig('inputTranscription', 'text') ||
                        server_content.dig('interimInputTranscription', 'text')
      model_transcript = server_content.dig('outputTranscription', 'text')

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
    notify_browser({ type: 'status', message: '面接が終了しました（切断されました）' })
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

  def start_mock_session
    @is_open = true
    @setup_completed = true
    notify_browser({
      type: 'setup_complete',
      message: '[MOCK] 面接の準備が完了しました。'
    })
    Thread.new do
      sleep 0.5
      notify_browser({
        type: 'gemini_response',
        audio_chunks: [],
        text: 'それでは模擬面接を始めます。まずは簡単に自己紹介をお願いします。',
        interrupted: false,
        turn_complete: true
      })
    end
  end
end
