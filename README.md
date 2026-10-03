# 外国籍生徒向けの高校入試面接練習のアプリ開発
## 外国籍の中学生向けの高校面接練習用のアプリ
- ブラウザ内で完結するアプリ
- 外国籍生徒の高校面接支援用

## 画面構成
- トップ
    - 最初の画面中央のタイトルの下に２つのボタンが表示される
    - モード選択のボタンを押すと次の画面に飛ぶ
- モード選択画面
    - 練習モード、本番モードの２つのボタンからモードを選択
    - モード選択のボタンにカーソルを合わせると説明を表示します
    - 練習モード、本番モードのボタンを押した場合、難易度選択画面に飛びます
- 難易度選択画面
    - Easy、Normal、Hardの３つのボタンから難易度を選択
- 出題画面
    - Gemini Liveを用いて、Geminiとユーザーの面接を実施します
    - 設定された難易度とモードに従い、問題を出題します
    - 画面中央に面接官となるキャラクターを配置
    - 画面左側の空きスペースにセリフとなるGemini Liveのテキストを表示します
    - 画面の下には音声対話を開始するボタンとモード選択へ戻るボタンの２つボタンを配置
    - 画面右上に練習モード 難易度：Easyと表示
    - 次の画面に遷移する
- 回答、アドバイス画面
    - 終了が確認されたとき、画面右寄りの中央にコーチングするキャラクターを配置
    - そのキャラクターの下側にふきだしをつくり、ふきだし内の左側には採点結果、右側にはアドバイスを表示する
    - ふきだしの下に終了してモード選択画面に戻るボタンともう一度そのモードと難易度を繰り返すボタンを配置

## システム詳細

### 1. 全体構成
このアプリは、ブラウザ上の音声対話 UI と、Ruby のサーバー、Gemini Live API を連携させた構成です。実際の通信は以下の流れで動作します。

1. ブラウザが `/ws` に WebSocket 接続を開く
2. Sinatra サーバーが `GeminiBridge` を生成する
3. `GeminiBridge` が `GEMINI_API_KEY` を確認し、APIキーが存在しない場合はモックモードで起動する
4. APIキーがある場合は、Gemini Live の WebSocket に接続して `setup` を送信する
5. Gemini が接続完了後に最初の質問を返し、ユーザーの音声入力を待機する
6. ブラウザ側でマイク入力と VAD（音声活動検出）が行われ、無音判定後に「turn_complete」をサーバーへ送る
7. サーバーがそのイベントを Gemini Live に転送し、Gemini の応答テキストと音声をブラウザへ返す
8. ブラウザは返ってきた音声を `AudioPlayer` で再生し、テキストは会話ログへ追加する

### 2. サーバー側の責務
`app.rb` は Sinatra ベースの Web アプリケーションで、ルーティングと WebSocket のハンドリングを担当します。

- `/` : トップ画面
- `/modes` : モード選択画面
- `/difficulty` : 難易度選択画面
- `/interview` : 面接画面の表示
- `/vocabulary` : 単語帳モード
- `/ordering` : 行動並び替えモード
- `/evaluate` : 面接の会話ログを受け取り採点結果を返す (POST)
- `/ws` : ブラウザと Gemini を接続する WebSocket エンドポイント
- `/health` : サーバーの正常性確認用エンドポイント

不正な `mode` / `difficulty` が渡された場合は `practice` / `normal` に補正されます。

`/ws` で受け取ったブラウザメッセージは、`GeminiBridge#handle_browser_message` に渡されます。メッセージには以下の種類があります。

- `audio` : マイク入力の PCM 音声データ
- `turn_complete` : ユーザーの発話終了を通知
- `text` : 文字入力メッセージ

サーバーからブラウザへ返すメッセージは次の通りです。

- `status` / `setup_complete` : 接続と準備の状態
- `gemini_response` : 音声チャンク、返答テキスト、ユーザーの文字起こし
- `coach_advice` : 練習モードでのコーチ役の助言
- `evaluation` : 採点結果とアドバイス
- `error` : エラー情報

### 3. Gemini Live 連携の詳細
`lib/gemini_bridge.rb` は、ブラウザと Gemini Live の橋渡し役です。主な処理は次の通りです。

- `start` : APIキーの有無でモックモードまたは本番モードを選択
- `connect_to_gemini` : Gemini Live の WebSocket に接続
- `build_setup_payload` : モデル設定と `systemInstruction` を構成
- `build_initial_trigger_payload` : 最初の質問を発火するための初期メッセージを作成
- `on_gemini_message` : Gemini からの `setupComplete` や `serverContent` を処理
- `safe_send` : Gemini へ JSON ベースのメッセージを送信

本番モードでは、以下の設定が送られます。

- モデル: `models/gemini-3.8-live`
- 音声出力: `AUDIO`
- 音声設定: `ja-JP` / `Puck` ボイス
- `realtimeInputConfig.activityHandling = START_OF_ACTIVITY_INTERRUPTS`
- `systemInstruction` には `prompts/interviewer.txt` の面接官プロンプトが設定される

`build_system_prompt` で、選択されたモードと難易度がプロンプトに追記されます。

- 練習モード: 1問ごとに受け止めながら進む
- 本番モード: 5問を順番に出題し、途中の助言は行わない
- 難易度: easy / normal / hard で質問の深さを変更

### 4. 音声入力・VAD の仕組み
ブラウザ側の `public/js/audio-recorder.js` は、マイク入力を取り込み、16kHz の PCM に変換して Gemini に送ります。

- `getUserMedia` でマイク入力を取得
- `AudioContext` で入力音声を処理
- `_downsampleTo16k` で入力サンプルを 16kHz に変換
- 16-bit PCM に変換して Base64 形式で送信
- 無音時間を `silenceThreshold` と `silenceDurationMs` で判定
- 無音時間が閾値を超えると `turn_complete` を送信して応答を切り替える

この設計により、ユーザーが話し終わったタイミングを自動的に検出し、Gemini の応答待ちに入ることができます。

### 5. 音声再生と表示
`public/js/audio-player.js` は Gemini から返ってきた音声を再生するための責務を持ちます。

- Gemini は 24kHz の PCM 音声を返す
- 受け取った Base64 をデコードして `AudioBuffer` に変換
- 連続した音声チャンクをバッファリングして滑らかに再生
- 割り込み時には `stop()` で再生を止める

テキスト応答は `public/js/app.js` で会話ログに追記されます。ユーザーの発話文と Gemini の応答文が同時に表示される構成で、対話の流れが可視化されます。

### 6. モックモードと障害耐性
`GEMINI_API_KEY` が未設定、または空文字のときは、`GeminiBridge#start_mock_session` が起動します。

- Gemini Live へ接続せずにモック応答を返す
- ローカル開発やデモ環境で UI を確認できる
- API キーがある条件でのみ本番接続を行う

また、WebSocket 接続が切れた場合や API エラー時は、`notify_browser` を使ってブラウザ側に `status` / `error` メッセージを送信し、ユーザーへ現状を伝えます。

### 7. 実装上の設計意図
このアプリの主要な設計意図は、「高校面接の練習をブラウザ内で完結させる」ことです。ユーザーはマイクとブラウザだけで面接練習を始められ、サーバー側は Gemini Live との橋渡しとセッション制御に集中しています。

これにより、以下の特性を実現しています。

- 外国籍生徒でも簡単に使えるブラウザベースのUI
- 日本語音声対話による自然な面接練習
- VAD による無音検知でターンを自動制御
- モックモードによる開発とデモの容易さ
- Ruby + WebSocket + Gemini Live のシンプルな連携アーキテクチャ

## モード別の機能
- 練習モード
    - 一問一答形式
    - その都度、画面右側に配置されたコーチ役のキャラクターからアドバイスを表示
    - アドバイスはコーチ役のキャラクターの下のふきだし内に表示
    - コーチ役のキャラと表示されたアドバイスは、面接官役のキャラクターに重ならない位置に配置
- 本番モードは面接の流れを再現し、終了後にアドバイスと採点結果を再現
- 本番モードの際はアドバイスはなし、
- 単語帳モードは面接で頻出する単語の意味や読みを表示
- 並び替えモードは並び替え形式で日本の面接マナーを学習
## 使用技術
- Ruby
- Gemini 3.8 Live
- サーバーでWebsocketを中継する

## ディレクトリ構成

```
.
├── .env                     # ローカル環境変数（GEMINI_API_KEY 等）
├── .env.example             # 環境変数テンプレート
├── .gitignore               # Git 除外設定
├── Gemfile                  # Ruby 依存関係定義
├── Gemfile.lock             # 依存関係ロックファイル
├── README.md                # 本プロジェクトの説明書
├── app.rb                   # Sinatra サーバー本体
├── config.ru                # Rack 起動設定
├── gemini_evaluator.rb      # 面接の採点ロジック（Gemini API）
├── kill_app.rb              # アプリ停止スクリプト
├── lib/
│   ├── gemini_bridge.rb     # Gemini Live WebSocket ブリッジ
│   └── interview_data.rb    # 単語帳・並び替えモードのデータ
├── prompts/
│   ├── evaluation.txt       # 採点用の評価基準
│   └── interviewer.txt      # 面接官用システムプロンプト
├── prompts.js               # プロンプト生成・連携用スクリプト
├── public/
│   ├── index.html           # ブラウザのメインHTML
│   ├── title                # 画面タイトル関連の静的ファイル
│   ├── style.css            # アプリ全体の共通スタイル
│   ├── script.js            # 画面制御用スクリプト
│   ├── css/
│   │   └── style.css        # UI用のCSS
│   └── js/
│       ├── app.js           # WebSocket と UI 連携
│       ├── audio-player.js  # Gemini 音声再生処理
│       └── audio-recorder.js# 16kHz PCM 録音・VAD 処理
├── test_app.rb              # テスト実行スクリプト
├── views/
│   ├── difficulty.erb       # 難易度選択画面
│   ├── index.erb            # トップ画面
│   ├── interview.erb        # 面接画面
│   ├── modes.erb            # モード選択画面
│   ├── ordering.erb         # 行動並び替えモード
│   └── vocabulary.erb       # 単語帳モード
├── 参考コード/
│   ├── Geminiライブとの通信コード/
│   ├── 面接官アニメーション：サンプルコード/
│   └── 面接練習システムUIコード/
└── .git/                   # Git 管理用（通常は除外対象）
```

> 実際の開発対象は上記の app.rb / lib / public / views / prompts 配下が中心です。参考コード配下は、参考実装やサンプルとして保持されているものです。

## 前提条件

- Ruby 3.2 以上 (本デモは Ruby 3.4.6 で動作確認済み)
- Bundler
- Google AI Studio の API キー (`GEMINI_API_KEY`)

## セットアップ

1. 依存ライブラリのインストール:
   ```bash
   bundle install
   ```

2. 環境変数の設定:
   `.env.example` をコピーして `.env` を作成し、Gemini APIキーを設定します。
   ```bash
   cp .env.example .env
   # .env 内の GEMINI_API_KEY をご自身のキーに書き換えてください
   ```
   ※ `GEMINI_API_KEY` を空欄にするとモックモードで起動します。有効なAPIキーを設定するとGemini Liveに接続します。

## 実行方法

### 1. サーバー起動
```bash
bundle exec ruby app.rb
```
起動後、ブラウザで [http://localhost:4567](http://localhost:4567) にアクセスします。

### 2. テストコード実行
```bash
bundle exec ruby test_app.rb
```
ユニットテスト、Rackインプロセステスト、および起動中サーバーへのE2Eテストが実行されます。

### 3. サーバー停止
```bash
ruby kill_app.rb
```
バックグラウンドまたは別ターミナルで起動中のサーバープロセスを安全に終了します。
