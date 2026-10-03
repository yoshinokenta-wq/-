require 'net/http'
require 'uri'
require 'json'
require 'tempfile'

# ==========================================
# 0. 多言語翻訳・辞書設定（クレカ・登録不要）
# ==========================================

# 1. 翻訳処理（無料API経由）
def translate_text(text, target_lang = "ja")
  url = URI.parse("https://api.mymemory.translated.net/get?q=#{URI.encode_www_form_component(text)}&langpair=autodetect|#{target_lang}")
  response = Net::HTTP.get(url)
  data = JSON.parse(response)
  data.dig("responseData", "translatedText") || text
rescue => e
  text
end

# 2. 言語ごとの評価観点ラベル（辞書）
EVALUATION_CRITERIA = {
  "ja" => {
    lang_name: "日本語",
    manner: "マナー・印象",
    conciseness: "簡潔性・要約力",
    logic: "論理的思考力",
    communication: "対話力",
    self_pr: "自己PR・意欲",
    advice_label: "アドバイス",
    default_advice: "具体的体験を交えて話すとアピール度UP！"
  },
  "en" => {
    lang_name: "English (英語)",
    manner: "Manner & Impression",
    conciseness: "Conciseness",
    logic: "Logical Thinking",
    communication: "Communication",
    self_pr: "Self-PR & Motivation",
    advice_label: "Advice",
    default_advice: "Great points! Try to add specific examples."
  }
}

# ==========================================
# 1. 各画面クラス (UI・描画担当)
# ==========================================

# トップ選択画面
class ModeSelectScreen
  attr_accessor :title_image, :mode_select_btn_image, :exit_btn_image, :settings_icon_image

  def initialize
    @title_image           = "assets/images/title_mode_select.png"
    @mode_select_btn_image = "assets/images/btn_mode_select.png"
    @exit_btn_image        = "assets/images/btn_exit.png"
    @settings_icon_image   = "assets/images/icon_settings_pentagon.png"
  end

  def render
    puts "========================================================================"
    puts "                                                 [S] ⚙️ 設定              "
    puts "                                                 Image: #{@settings_icon_image}"
    puts "------------------------------------------------------------------------"
    puts ""
    puts "                     ==============================                     "
    puts "                     │          タイトル画面          │                     "
    puts "                     ==============================                     "
    puts "                     Image: #{@title_image}"
    puts ""
    puts "                     ┌──────────────────────────┐                       "
    puts "                     │       1. モード選択       │                       "
    puts "                     └──────────────────────────┘                       "
    puts "                     Image: #{@mode_select_btn_image}"
    puts ""
    puts "                     ┌──────────────────────────┐                       "
    puts "                     │        2. おわる         │                       "
    puts "                     └──────────────────────────┘                       "
    puts "                     Image: #{@exit_btn_image}"
    puts ""
    puts "========================================================================"
  end

  def handle_input
    print "👉 操作を選んでください (1: モード選択 / 2: おわる / S: 設定): "
    choice = gets.chomp.downcase

    case choice
    when "1" then :goto_mode_list
    when "2" then :exit_app
    when "s" then :open_settings
    else
      puts "⚠️ 無効な入力です。"
      nil
    end
  end
end

# モード選択画面
class ModeListScreen
  attr_accessor :practice_btn_image, :real_btn_image, :manner_btn_image, :vocab_btn_image, :back_btn_image

  def initialize
    @practice_btn_image = "assets/images/btn_mode_practice.png"
    @real_btn_image     = "assets/images/btn_mode_real.png"
    @manner_btn_image   = "assets/images/btn_mode_manner.png"
    @vocab_btn_image    = "assets/images/btn_mode_vocab.png"
    @back_btn_image     = "assets/images/btn_back.png"
  end

  def render
    puts "========================================================================"
    puts "                       【 モード選択 】                          "
    puts "========================================================================"
    puts ""
    puts "  ┌──────────────────────────┐                                  "
    puts "  │       1. 練習モード       │ (左上)                           "
    puts "  └──────────────────────────┘                                  "
    puts "  Image: #{@practice_btn_image}"
    puts ""
    puts "                                    ┌──────────────────────────┐"
    puts "                                    │       2. 本番モード       │ (右下)"
    puts "                                    └──────────────────────────┘"
    puts "                                    Image: #{@real_btn_image}"
    puts ""
    puts "  ┌──────────────────────────┐                                  "
    puts "  │   3. マナー並び替え      │ (左下)                           "
    puts "  └──────────────────────────┘                                  "
    puts "  Image: #{@manner_btn_image}"
    puts ""
    puts "                                    ┌──────────────────────────┐"
    puts "                                    │       4. 単語帳モード    │ (右下)"
    puts "                                    └──────────────────────────┘"
    puts "                                    Image: #{@vocab_btn_image}"
    puts ""
    puts "------------------------------------------------------------------------"
    puts "  [B] もどる (Image: #{@back_btn_image})"
    puts "========================================================================"
  end

  def handle_input
    print "👉 やりたいモードを選んでください (1〜4 / B: もどる): "
    choice = gets.chomp.downcase

    case choice
    when "1" then :practice_mode
    when "2" then :real_mode
    when "3" then :manner_mode
    when "4" then :vocab_mode
    when "b" then :back
    else
      puts "⚠️ 1〜4 の番号か「B」を入力してください。"
      nil
    end
  end
end

# 難易度選択画面
class DifficultySelectScreen
  GREEN  = "\e[32m"
  YELLOW = "\e[33m"
  RED    = "\e[31m"
  RESET  = "\e[0m"

  def initialize(mode_name)
    @mode_name = mode_name
  end

  def render
    centered_mode = @mode_name.center(28)

    puts "========================================================================"
    puts ""
    puts "                     ┌──────────────────────────┐"
    puts "                     │#{centered_mode}│"
    puts "                     └──────────────────────────┘"
    puts ""
    puts "                                    ┌──────────────────────────┐"
    puts "                                    │ 1. #{GREEN}Easy#{RESET}                  │"
    puts "                                    └──────────────────────────┘"
    puts "  難易度選択                         ┌──────────────────────────┐"
    puts "                                    │ 2. #{YELLOW}Normal#{RESET}                │"
    puts "                                    └──────────────────────────┘"
    puts "                                    ┌──────────────────────────┐"
    puts "                                    │ 3. #{RED}Hard#{RESET}                  │"
    puts "                                    └──────────────────────────┘"
    puts ""
    puts "========================================================================"
  end

  def handle_input
    print "👉 難易度を選んでください (1: Easy / 2: Normal / 3: Hard): "
    choice = gets.chomp

    case choice
    when "1" then "Easy"
    when "2" then "Normal"
    when "3" then "Hard"
    else
      puts "⚠️ 1〜3 の番号を入力してください。"
      nil
    end
  end
end

# 面接対話画面
class HardModeInterviewScreen
  CYAN      = "\e[36m"
  BG_CYAN   = "\e[46m\e[30m"
  RESET     = "\e[0m"

  PARTS_CONFIG = {
    glasses: "┌─┬─┐",
    eyes: " 👁 👁 ",
    mouths: {
      closed: "  -  ",
      open_a: "  口  "
    },
    body: " /| |\\ "
  }.freeze

  def initialize(mode_name, difficulty)
    @mode_name = mode_name
    @difficulty = difficulty
    @current_mouth = :closed
  end

  def set_mouth(mouth_type)
    @current_mouth = mouth_type if PARTS_CONFIG[:mouths].key?(mouth_type)
  end

  def render(question_text = "", current_step = 1)
    header_left = "#{@mode_name} #{@difficulty}"
    header_right = @mode_name == "本番モード" ? "" : "※アドバイスあり"
    header_line = "#{header_left.ljust(45)}#{header_right.rjust(27)}"

    line1 = question_text[0..20] || ""
    line2 = question_text[21..41] || ""
    line3 = question_text[42..62] || ""

    m_mouth = PARTS_CONFIG[:mouths][@current_mouth]

    progress_bar = (1..5).map do |num|
      num == current_step ? "#{BG_CYAN}[#{num}]#{RESET}" : "[#{num}]"
    end.join(" ── ")

    puts "========================================================================"
    puts " #{header_line}"
    puts "------------------------------------------------------------------------"
    puts ""
    puts "  ┌─────────────────────────────────────────┐"
    puts "  │ #{line1.ljust(40)}│    #{PARTS_CONFIG[:glasses]} (眼鏡)"
    puts "  │ #{line2.ljust(40)}│   / #{PARTS_CONFIG[:eyes]} \\ (顔+目)"
    puts "  │ #{line3.ljust(40)}│  │  #{m_mouth}  │ (口パーツ: #{@current_mouth})"
    puts "  └───────────────┬─────────────────────────┘   #{PARTS_CONFIG[:body]} (体)"
    puts "                  ＼"
    puts ""
    puts "------------------------------------------------------------------------"
    puts "  進行度 :  #{progress_bar}"
    puts "========================================================================"
  end
end

# 最終評価画面（多言語自動対応版）
class FinalEvaluationScreen
  BOLD  = "\e[1m"
  GREEN = "\e[32m"
  RESET = "\e[0m"

  def render(eval_result)
    final_grade = eval_result[:final_grade]
    avg_score   = eval_result[:avg_score]
    scores      = eval_result[:scores]
    lang_code   = eval_result[:lang_code]
    labels      = EVALUATION_CRITERIA[lang_code] || EVALUATION_CRITERIA["ja"]

    advice_text = labels[:default_advice]
    adv1 = advice_text[0..11] || ""
    adv2 = advice_text[12..23] || ""

    puts "========================================================================"
    puts " :  :  :  :  :  :  :  : ( 多言語判定・評価結果 ) :  :  :  :  :  :  :  :  : "
    puts "------------------------------------------------------------------------"
    puts "  ╔══════════════════════════════════════════════════════════════════╗"
    puts "  ║                            (  o.o  )                            ║"
    puts "  ║                             >  🦉 <   【 フクロウ教授 】          ║"
    puts "  ║                            (  \"\"  )                              ║"
    puts "  ║                                                                  ║"
    puts "  ║   🌐 判定言語 : #{labels[:lang_name].ljust(48)} ║"
    puts "  ║  ╭──────────────────────────╮    ╭──────────────────────────╮  ║"
    puts "  ║  │ 📊 Score (Avg:#{sprintf('%.1f', avg_score)}pt)  │    │ 💡 #{labels[:advice_label].ljust(20)} │  ║"
    puts "  ║  │ ──────────────────────── │    │ ──────────────────────── │  ║"
    puts "  ║  │  総合: #{BOLD}#{GREEN}[ #{final_grade} 判定 ]#{RESET}      │    │ #{adv1.ljust(24)} │  ║"
    puts "  ║  │  ・#{labels[:manner].ljust(12)} : #{scores[:manner]}     │    │ #{adv2.ljust(24)} │  ║"
    puts "  ║  │  ・#{labels[:conciseness].ljust(12)} : #{scores[:conciseness]}     │    │                          │  ║"
    puts "  ║  │  ・#{labels[:logic].ljust(12)} : #{scores[:logic]}     │    │                          │  ║"
    puts "  ║  │  ・#{labels[:communication].ljust(12)} : #{scores[:communication]}     │    │                          │  ║"
    puts "  ║  │  ・#{labels[:self_pr].ljust(12)} : #{scores[:self_pr]}     │    │                          │  ║"
    puts "  ║  ╰──────────────────────────╯    ╰──────────────────────────╯  ║"
    puts "  ╚══════════════════════════════════════════════════════════════════╝"
    puts ""
    puts "   ┌──────────────┐                                  ┌──────────────┐   "
    puts "   │  1. おわる   │                                  │ 2. もう一度  │   "
    puts "   └──────────────┘                                  └──────────────┘   "
    puts "========================================================================"
  end

  def handle_input
    print "👉 次の操作を選んでください (1: おわる / 2: もう一度): "
    choice = gets.chomp

    case choice
    when "1" then :exit_app
    when "2" then :retry_interview
    else
      puts "⚠️ 1 または 2 を入力してください。"
      nil
    end
  end
end

# ==========================================
# 2. 音声・評価・面接官サービス
# ==========================================

class MultilingualVoiceService
  def process_user_input(user_text)
    is_english = user_text.match?(/[a-zA-Z]/)
    lang_code = is_english ? "en" : "ja"
    translated_text = is_english ? translate_text(user_text, "ja") : user_text

    {
      raw_text: user_text,
      translated_text: translated_text,
      lang_code: lang_code
    }
  end

  def speak_interviewer_response(text)
    puts "[システム] 🔊 （音声再生中...: 「#{text}」）"

    if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
      # 一時的にVBScriptを作成して読み上げる方式（構文エラーを完璧に回避）
      vbs_file = Tempfile.new(['tts', '.vbs'])
      vbs_file.write("Set sapi = CreateObject(\"SAPI.SpVoice\")\nsapi.Speak \"#{text.gsub('"', '""')}\"")
      vbs_file.close
      
      system("cscript //nologo \"#{vbs_file.path}\"")
      vbs_file.unlink
    elsif RUBY_PLATFORM =~ /darwin/
      system("say -v Kyoko '#{text}'")
    end
  end
end

# 5つの観点に基づいた評価ロジック
class InterviewEvaluator
  GRADE_POINTS = { 'S' => 5.0, 'A' => 4.0, 'B' => 3.0, 'C' => 2.0, 'D' => 1.0 }.freeze

  def self.provide_instant_feedback(question, processed_data)
    raw = processed_data[:raw_text]
    lang = processed_data[:lang_code]

    puts "\n💡 【練習モード：AIからのワンポイントアドバイス】"
    if lang == "en"
      puts "🌐 [自動検出] 英語を検出しました！（日本語訳: 「#{processed_data[:translated_text]}」）"
    end

    if raw.length < 15
      puts "👉 [簡潔性/自己PR] 回答が少し短いです。具体例をもう少し足してみましょう！"
    else
      puts "👉 [評価] しっかりした長さで答えられていて素晴らしいです！"
    end
    puts "--------------------------------------------------"
  end

  def self.evaluate_all(history)
    scores = {
      manner:        eval_manner(history),
      conciseness:   eval_conciseness(history),
      logic:         eval_logic(history),
      communication: eval_communication(history),
      self_pr:       eval_self_pr(history)
    }

    primary_lang = history.any? { |h| h[:lang_code] == "en" } ? "en" : "ja"

    pts = scores.values.map { |g| GRADE_POINTS[g] }
    avg = pts.sum / pts.size.to_f

    final_rank = case avg
                 when 4.5..5.0 then 'S'
                 when 3.5...4.5 then 'A'
                 when 2.5...3.5 then 'B'
                 when 1.5...2.5 then 'C'
                 else 'D'
                 end

    {
      scores: scores,
      avg_score: avg,
      final_grade: final_rank,
      lang_code: primary_lang
    }
  end

  private

  def self.eval_manner(history)
    polite_count = history.count { |h| h[:raw_text].include?("です") || h[:raw_text].include?("ます") || h[:lang_code] == "en" }
    case polite_count
    when 4..5 then 'S'
    when 2..3 then 'A'
    else 'B'
    end
  end

  def self.eval_conciseness(history)
    avg_len = history.map { |h| h[:raw_text].length }.sum / [history.size, 1].max
    case avg_len
    when 25..60 then 'S'
    when 15..24 then 'A'
    else 'B'
    end
  end

  def self.eval_logic(history)
    logic_words = ["because", "why", "so", "なぜなら", "理由", "だから"]
    count = history.count { |h| logic_words.any? { |w| h[:raw_text].downcase.include?(w) } }
    case count
    when 2..5 then 'S'
    when 1    then 'A'
    else 'B'
    end
  end

  def self.eval_communication(history)
    valid_answers = history.count { |h| h[:raw_text].length >= 5 }
    case valid_answers
    when 5 then 'S'
    when 3..4 then 'A'
    else 'B'
    end
  end

  def self.eval_self_pr(history)
    pr_words = ["hard", "study", "future", "goal", "頑張", "強み", "目標", "経験"]
    count = history.count { |h| pr_words.any? { |w| h[:raw_text].downcase.include?(w) } }
    case count
    when 3..5 then 'S'
    when 1..2 then 'A'
    else 'B'
    end
  end
end

class AIInterviewer
  attr_reader :difficulty

  def initialize(difficulty)
    @difficulty = difficulty
  end

  def ask_question(question_num)
    case @difficulty
    when "Easy"
      case question_num
      when 1 then "はじめまして。学校の志望動機を教えてください。"
      when 2 then "中学校の生活で、一番がんばったことは何ですか？"
      when 3 then "日本で生活していて、母国との文化の違いで困ったことはありますか？"
      when 4 then "高校に入ったら、どんなことに挑戦してみたいですか？"
      when 5 then "将来の夢や、やってみたい仕事を教えてください。"
      else "以上で面接は終わりです。お疲れ様でした。"
      end
    when "Hard"
      case question_num
      when 1 then "本校を志望した理由と決定的な決定打を教えてください。"
      when 2 then "中学校で最も努力したことと、その経験をどう活かしますか？"
      when 3 then "文化の違いで困った体験と、それを乗り越えた方法を教えてください。"
      when 4 then "高校入学後に挑戦したいことと、具体計画を教えてください。"
      when 5 then "将来就きたい職業と、その背景を聞かせてください。"
      else "以上で面接を終了します。回答ありがとうございました。"
      end
    else # Normal
      case question_num
      when 1 then "本日はよろしくお願いします。本校を志望した理由を教えてください。"
      when 2 then "中学校生活で一番頑張ったことは何ですか？"
      when 3 then "母国と日本の文化の違いで困ったことは何ですか？"
      when 4 then "高校に入ったら、どんなことに挑戦してみたいですか？"
      when 5 then "将来の夢や、やってみたい仕事について教えてください。"
      else "以上で面接を終了します。お疲れ様でした。"
      end
    end
  end
end

# ==========================================
# 3. 面接アプリ本体（全体のコントローラー）
# ==========================================
class InterviewApp
  def initialize
    @selected_mode = nil
    @selected_difficulty = "Normal"
    @voice_service = MultilingualVoiceService.new
    
    @mode_select_screen       = ModeSelectScreen.new
    @mode_list_screen         = ModeListScreen.new
    @final_evaluation_screen  = FinalEvaluationScreen.new
  end

  def run
    loop do
      @mode_select_screen.render
      action = @mode_select_screen.handle_input

      case action
      when :goto_mode_list
        select_mode_from_list
        break if @selected_mode
      when :exit_app
        puts "\nアプリを終了します。お疲れ様でした！"
        return
      when :open_settings
        puts "\n⚙️ 設定画面を開きます（実装予定）"
      end
    end

    start_selected_mode
  end

  private

  def select_mode_from_list
    @mode_list_screen.render
    choice = @mode_list_screen.handle_input

    case choice
    when :practice_mode then @selected_mode = "練習モード"
    when :real_mode     then @selected_mode = "本番モード"
    when :manner_mode   then @selected_mode = "面接マナー並び替えモード"
    when :vocab_mode    then @selected_mode = "単語帳モード"
    when :back          then @selected_mode = nil
    end
  end

  def start_selected_mode
    case @selected_mode
    when "単語帳モード"
      start_vocab_mode
    when "面接マナー並び替えモード"
      start_manner_mode
    else
      select_difficulty
      start_interview
    end
  end

  def select_difficulty
    diff_screen = DifficultySelectScreen.new(@selected_mode)
    
    loop do
      diff_screen.render
      result = diff_screen.handle_input
      if result
        @selected_difficulty = result
        break
      end
    end

    puts "\n[システム] 難易度を「#{@selected_difficulty}」に設定しました！"
    sleep(1)
  end

  def start_interview
    interviewer = AIInterviewer.new(@selected_difficulty)
    interview_history = []
    
    ui_screen = HardModeInterviewScreen.new(@selected_mode, @selected_difficulty)

    (1..5).each do |q_num|
      question_text = interviewer.ask_question(q_num)

      ui_screen.set_mouth(:open_a)
      ui_screen.render(question_text, q_num)

      @voice_service.speak_interviewer_response(question_text)
      ui_screen.set_mouth(:closed)

      print "\n👉 あなたの回答を入力してください (日本語/英語 OK): "
      user_answer = gets.chomp
      processed_data = @voice_service.process_user_input(user_answer)

      interview_history << {
        question: question_text,
        raw_text: processed_data[:raw_text],
        translated_text: processed_data[:translated_text],
        lang_code: processed_data[:lang_code]
      }

      if @selected_mode == "練習モード"
        InterviewEvaluator.provide_instant_feedback(question_text, processed_data)
      end
    end

    eval_result = InterviewEvaluator.evaluate_all(interview_history)

    loop do
      @final_evaluation_screen.render(eval_result)
      action = @final_evaluation_screen.handle_input

      case action
      when :exit_app
        puts "\nアプリを終了します。お疲れ様でした！"
        break
      when :retry_interview
        start_interview
        break
      end
    end
  end

  def start_vocab_mode
    puts "\n📖 【単語帳モード】"
    gets
  end

  def start_manner_mode
    puts "\n🧩 【面接マナー並び替えモード】"
    gets
  end
end

# ==========================================
# 4. アプリ起動処理
# ==========================================
app = InterviewApp.new
app.run