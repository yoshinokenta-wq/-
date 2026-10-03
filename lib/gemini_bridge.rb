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

  TOTAL_QUESTIONS = 5

  MODE_LABELS = {
    'practice' => '練習モード',
    'real' => '本番モード'
  }.freeze
  
  def self.load_prompt(file_name)
    path = File.join(__dir__, '..', 'prompts', file_name)
    File.exist?(path) ? File.read(path, encoding: 'utf-8').strip : nil
  rescue StandardError
    nil
  end

  # 面接官のベースプロンプト
  def self.default_system_prompt
    load_prompt('interviewer.txt') ||
      'あなたは企業の採用面接官です。応募者に対する模擬面接を行ってください。' \
      '実際の面接らしく、まずは自己紹介や志望動機などの質問を1つずつ投げかけてください。'
  end

  attr_reader :browser_ws, :gemini_client, :is_open, :setup_completed

  def initialize(browser_ws, options = {})
    @browser_ws = browser_ws
    @api_key = options[:api_key] || ENV['GEMINI_API_KEY']
    @model = format_model_name(options[:model] || ENV['GEMINI_MODEL'] || DEFAULT_MODEL)
    @voice = options[:voice] || ENV['GEMINI_VOICE'] || DEFAULT_VOICE
    @mode = (options[:mode] || ENV['GEMINI_MODE'] || 'practice').to_s
    @difficulty = (options[:difficulty] || ENV['GEMINI_DIFFICULTY'] || 'normal').to_s.downcase
    @system_prompt = options[:system_prompt] || build_system_prompt
    @logger = options[:logger] || Logger.new($stdout)
    @gemini_client = nil
    @is_open = false
    @setup_completed = false
    @activity_started = false
    @audio_chunks_sent = 0
    @mock_mode = options[:mock_mode] || false
  end

  def mode
    @mode
  end

  def difficulty
    @difficulty
  end

  # 難易度ごとの出題指引
  def difficulty_rule
    case @difficulty
    when 'easy'
      'やさしい入門レベル。1〜2文で答えられる具体的な話題（趣味、部活など）に絞った質問にする。'
    when 'hard'
      '難しいレベル。"Why"を掘り下げる抽象的な質問や、考えを聞かせる質問を中心にする。'
    else
      '一般的な高校入試レベル。志望理由や中学での経験を絡めた質問にする。'
    end
  end

  # モードごとの面接の進め方
  def mode_instruction
    if @mode == 'real'
      "実際の入試と同じように、#{TOTAL_QUESTIONS}問を順番に出題してください。" \
        '途中のコメント・評価・助言は一切しないでください。' \
        '最後に「以上、本日の面接は終わりました。ありがとうございました。」と伝えてください。'
    else
      '1問ごとに、相手の回答を短い言葉で受け止めたうえで、次の質問に進んでください。' \
        '相手が詰まっても答えを急かさないでください。'
    end
  end

  # ベースプロンプトにモードと難易度の条件を付与する
  def build_system_prompt
    base = self.class.default_system_prompt
    mode_label = MODE_LABELS.fetch(@mode, '練習モード')

    conditions = [
      '【今回の面接条件】',
      "モード: #{mode_label}",
      "難易度: #{@difficulty.upcase}",
      "総質問数: #{TOTAL_QUESTIONS}問",
      '',
      "【難易度の指針】#{difficulty_rule}",
      "【#{mode_label}の進め方】#{mode_instruction}"
    ]

    "#{base}\n\n#{conditions.join("\n")}"
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
    @activity_started = false
    @audio_chunks_sent = 0
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
            disabled: true
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
