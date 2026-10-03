# RubyでGemini Liveを使用するデモ

Ruby（Sinatra + Puma）を使ったWebアプリケーションで、Gemini 3.8 Live API を使用したリアルタイム双方向音声チャットを実現するデモプロジェクトです。

## 構成

- **サーバーサイドプロキシ**: ブラウザと Gemini Live 間の通信をサーバー（Sinatra）が安全に中継（APIキーをブラウザに露出しません）。
- **モデル**: `Gemini 3.8 Live` (`models/gemini-3.8-live`)
- **サーバー**: Sinatra + Puma
- **サーバー ↔ Gemini**: `websocket-client-simple` を使用して Gemini Live API の双方向 WebSocket エンドポイントに接続
- **ブラウザ ↔ サーバー**: `faye-websocket` を使用
- **無音判定 (VAD)**: ブラウザ上でマイク入力の実効音量（RMS）を監視し、設定時間以上無音が継続したら自動的にターン終了シグナル（`turn_complete`）を送信
- **初回発話**: 接続完了後、Gemini 側から最初のターンを開始して挨拶音声を生成し、ブラウザ上で再生

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
   ※ APIキーが設定されていない場合は、テスト用のモックモードで起動します。

## 実行方法

### 1. サーバー起動
```bash
ruby app.rb
```
起動後、ブラウザで [http://localhost:4567](http://localhost:4567) にアクセスします。

### 2. テストコード実行
```bash
ruby test_app.rb
```
ユニットテスト、Rackインプロセステスト、および起動中サーバーへのE2Eテストが実行されます。

### 3. サーバー停止
```bash
ruby kill_app.rb
```
バックグラウンドまたは別ターミナルで起動中のサーバープロセスを安全に終了します。

## ディレクトリ構成

```
.
├── app.rb                   # サーバー本体 (Sinatra + Puma + Faye::WebSocket)
├── kill_app.rb              # サーバー停止スクリプト
├── test_app.rb              # テストスクリプト
├── config.ru                # Rack設定
├── Gemfile                  # 依存gem定義
├── .env.example             # 環境変数テンプレート
├── lib/
│   └── gemini_bridge.rb     # Gemini 3.8 Live API WebSocket ブリッジ
└── public/
    ├── index.html           # チャットUI画面
    ├── css/
    │   └── style.css        # スタイルシート
    └── js/
        ├── audio-player.js  # 24kHz PCM 音声再生キュー
        ├── audio-recorder.js# 16kHz PCM 録音 & 無音判定 (VAD)
        └── app.js           # UI & WebSocket 連携ロジック
```

## 主な機能

- **リアルタイム音声通話**: マイクからの音声を 16kHz PCM に変換してストリーミング送信。Geminiからの 24kHz PCM 音声をバッファリングしてギャップレス再生。
- **無音判定 (VAD) & 視覚化**: 音量レベルバー、しきい値ライン、無音タイマーのカウントダウンを表示。しきい値と無音判定時間は画面上のスライダーでリアルタイム調整可能。
- **割り込み発話 (Interruption)**: Gemini が話している途中に話しかけると、再生中の音声が自動的に停止し、ユーザーのターンへ交代。
