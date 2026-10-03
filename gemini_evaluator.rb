# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# 面接の回答を Gemini API で評価するモジュール
module GeminiEvaluator
  EVALUATION_MODEL = 'gemini-2.5-flash'
  API_BASE = 'https://generativelanguage.googleapis.com/v1'

  # 評価観点（READMEの採点基準に対応）
  CRITERIA = [
    { key: 'manner',        label: 'マナー・印象' },
    { key: 'conciseness',   label: '簡潔性・要約力' },
    { key: 'logic',         label: '論理的思考力' },
    { key: 'communication', label: '対話力' },
    { key: 'self_pr',       label: '自己PR・意欲' }
  ].freeze

  DEFAULT_ADVICE = 'Primary advice could not be generated.'

  module_function

  # 面接全体のログから評価結果（採点 + アドバイス）を返す
  # transcript: [{ role: 'interviewer'|'user', text: '...' }, ...]
  def evaluate(transcript)
    api_key = ENV['GEMINI_API_KEY']
    return unavailable_result if api_key.nil? || api_key.strip.empty?

    prompt = build_prompt(transcript)
    raw = call_api(prompt, api_key)
    return unavailable_result if raw.nil?

    parse_result(raw)
  end

  def unavailable_result
    {
      score_text: '評価できません',
      advice_text: 'GEMINI_API_KEY が設定されていません。',
      average: nil,
      rank: nil,
      scores: {}
    }
  end

  def build_prompt(transcript)
    conversation = transcript.map do |entry|
      label = entry[:role] == 'user' ? '【考生】' : '【面接官】'
      "#{label}#{entry[:text]}"
    end.join("\n")

    criteria_lines = CRITERIA.map { |c| "- #{c[:label]}" }.join("\n")

    <<~PROMPT
      あなたは高校入試の面接官です。以下の面接のやり取りを評価してください。

      #{conversation}

      以下の5つの観点それぞれを、S/A/B/C/D の5段階で判定してください。
      #{criteria_lines}

      出力は次の形式に厳密に従ってください（Markdown記法は使わないでください）。

      総合評価: <S/A/B/C/D>
      平均点: <1.0〜5.0の数値>
      マナー・印象: <S/A/B/C/D>
      簡潔性・要約力: <S/A/B/C/D>
      論理的思考力: <S/A/B/C/D>
      対話力: <S/A/B/C/D>
      自己PR・意欲: <S/A/B/C/D>
      アドバイス: <次に挑戦するための具体的な助言を200字程度で>
    PROMPT
  end

  def call_api(prompt, api_key)
    uri = URI.parse("#{API_BASE}/models/#{EVALUATION_MODEL}:generateContent?key=#{api_key}")
    payload = { contents: [{ parts: [{ text: prompt }] }] }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri.request_uri, { 'Content-Type' => 'application/json' })
    request.body = payload.to_json

    response = http.request(request)
    result = JSON.parse(response.body)
    result.dig('candidates', 0, 'content', 'parts', 0, 'text')
  rescue StandardError => e
    warn("[GeminiEvaluator] API呼び出しに失敗しました: #{e.message}")
    nil
  end

  # 評価テキストを構造化する
  def parse_result(raw)
    scores = {}
    rank = nil
    average = nil
    advice = ''
    current_key = nil

    raw.each_line do |line|
      stripped = line.strip
      next if stripped.empty?

      case stripped
      when /\A総合評価[:：]\s*(.+)\z/
        rank = Regexp.last_match(1).strip
        current_key = :rank
      when /\A平均点[:：]\s*(.+)\z/
        average = Float(Regexp.last_match(1).strip) rescue nil
        current_key = :average
      when /\Aアドバイス[:：]\s*(.*)\z/
        advice = Regexp.last_match(1).strip
        current_key = :advice
      else
        CRITERIA.each do |criterion|
          if stripped =~ /\A#{Regexp.escape(criterion[:label])}[:：]\s*(.+)\z/
            scores[criterion[:key]] = Regexp.last_match(1).strip
            current_key = nil
            break
          end
        end

        # 継続行は PRAX.advice の追記として扱う
        advice << " #{stripped}" if current_key == :advice
      end
    end

    {
      score_text: format_score_text(scores, rank, average),
      advice_text: advice.empty? ? DEFAULT_ADVICE : advice,
      average: average,
      rank: rank,
      scores: scores
    }
  end

  def format_score_text(scores, rank, average)
    lines = []
    lines << "総合評価: #{rank || '-'}"
    lines << "平均点: #{average ? format('%.1f', average) : '-'}"
    lines << ''
    CRITERIA.each do |criterion|
      value = scores[criterion[:key]]
      lines << "#{criterion[:label]}: #{value || '-'}"
    end
    lines.join("\n")
  end
end