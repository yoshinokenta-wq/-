require 'sinatra'

enable :sessions
set :host_authorization, { permitted_hosts: [] }

# prompts フォルダの中身を安全に読み取るための関数
def load_prompt(file_name)
  file_path = File.join(__dir__, 'prompts', file_name)
  
  if File.exist?(file_path)
    File.read(file_path, encoding: 'UTF-8')
  else
    puts "【警告】#{file_name} が見つかりません！"
    ""
  end
end

# ===== 各ページ（GET処理） =====

# 1. トップページ
get '/' do
  session[:lang] ||= 'ja' # デフォルトを日本語にセット
  erb :index
end

# トップページ
get '/' do
  erb :index
end

# ★ここに評価用のルートを追加！
post '/evaluate' do
  # チームメンバーのプロンプトを読み込み
  eval_instruction = load_prompt('evaluation.txt')
  
  # ユーザーの回答データと合体させる
  user_answers = params[:answers] # 送られてきた回答
  full_prompt = "#{eval_instruction}\n\n【ユーザーの回答】\n#{user_answers}"

  # ここで Gemini API などを呼び出して評価を受け取る
  # ...
end

# 2. モード選択画面（トップから移動する場所）
get '/modes' do
  @lang = session[:lang] || 'ja'
  erb :modes
end

# 3. 面接練習画面（本番モードの難易度分岐）
get '/interview' do
  @mode = params[:mode]
  @difficulty = params[:difficulty]

  # modeが'real'で、かつdifficultyが指定されていない（または空）場合は難易度選択画面へ
  if @mode == 'real' && (@difficulty.nil? || @difficulty.empty?)
    erb :difficulty
  else
    erb :interview
  end
end

# 4. 言語設定画面
get '/settings' do
  erb :settings
end


# ===== データ受信用（POST処理） =====

# 面接回答の受信処理
post '/interview' do
  @user_answer = params[:answer]
  @question = "あなたの強み（長所）と、それを活かした経験を教えてください。"
  erb :interview
end

# 言語判定・保存処理
post '/settings' do
  user_input = params[:user_input].to_s.strip

  if user_input =~ /[一-龠ぁ-んァ-ヶ]/
    session[:lang] = 'ja'
  else
    session[:lang] = 'en'
  end

  puts "現在の言語設定: #{session[:lang]} (入力値: '#{user_input}')"
  redirect '/'
end