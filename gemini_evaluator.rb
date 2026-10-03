require 'net/http'
require 'uri'
require 'json'

module GeminiEvaluator
  def self.evaluate_text(user_answer, question_text, question_num)
    api_key = ENV['GEMINI_API_KEY']
    return "GEMINI_API_KEY が設定されていません。" if api_key.nil? || api_key.empty?

    prompt = <<~TEXT
      あなたはプロの採用面接官兼フィードバックアナリストです。
      第#{question_num}問目の質問「#{question_text}」に対し、求職者が以下の回答をしました。
      
      【ユーザーの回答】
      #{user_answer}
      
      以下の4点について日本語で簡潔かつ親切に評価テキストを出力してください。
      1. 【内容の受け止め】回答の意図が伝わっているか
      2. 【回答内容の評価】論理的わかりやすさ・具体性
      3. 【表現力】言葉遣いやアピール度
      4. 【アドバイス】次回に向けた改善点
    TEXT

    call_api(prompt)
  end

  def self.evaluate_final(answers, questions)
    api_key = ENV['GEMINI_API_KEY']
    return "GEMINI_API_KEY が設定されていません。" if api_key.nil? || api_key.empty?

    qa_pairs = questions.each_with_index.map do |q, i|
      "【質問#{i+1}】:#{q}\n【回答#{i+1}】:#{answers[i]}"
    end.join("\n\n")

    prompt = <<~TEXT
      あなたはプロの採用面接官です。以下の模擬面接のすべてのやり取りを通しで評価し、総評と総合的なアドバイスを日本語で詳しく出力してください。
      
      #{qa_pairs}
    TEXT

    call_api(prompt)
  end

  def self.call_api(prompt)
    api_key = ENV['GEMINI_API_KEY']
    uri = URI.parse("https://generativelanguage.googleapis.com/v1/models/gemini-2.5-flash:generateContent?key=#{api_key}")
    payload = {
      contents: [
        {
          parts: [{ text: prompt }]
        }
      ]
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri, { 'Content-Type' => 'application/json' })
    request.body = payload.to_json

    response = http.request(request)
    result = JSON.parse(response.body) rescue nil

    if result && result['candidates'] && result['candidates'][0] &&
       result['candidates'][0]['content'] &&
       result['candidates'][0]['content']['parts'] &&
       result['candidates'][0]['content']['parts'][0]['text']
      result['candidates'][0]['content']['parts'][0]['text']
    else
      "評価の取得に失敗しました。"
    end
  end
end
