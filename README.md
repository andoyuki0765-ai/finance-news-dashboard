# 📰 金融ニュースダッシュボード

無料RSSから日本の金融・経済ニュースを毎朝自動取得し、14単元別にAI要約付きダッシュボードを生成するシステムです。

🌐 **公開ダッシュボード**: https://andoyuki0765-ai.github.io/finance-news-dashboard/

## 🎯 特徴

- **自動収集**: NHK、Yahoo!、ロイター、Bloomberg、朝日、東洋経済等の公開RSSから直近24時間の記事を取得
- **単元別分類**: 14テーマ（金融政策・為替・株式・商品・暗号資産・インフレ・雇用・企業業績・テック・地政学・不動産・M&A・日本経済・世界経済）
- **AI要約**: Claude が単元ごとに「本日の動き／過去の文脈／注目点／センチメント」を生成
- **時系列追跡**: 過去の記事履歴を蓄積し、テーマの変遷を追跡
- **完全ローカル＋公開**: ローカルWindowsで生成、GitHub Pagesで公開

## 🏗 アーキテクチャ

```
[ローカル6:00 タスクスケジューラ]                [Routine 6:30]
   ↓                                                ↓
   fetch → categorize → summarize → generate        GitHubから
   ↓                                                サマリ取得
   git push → GitHub                                ↓
   ↓                                                Gmail通知
   GitHub Pages（スマホ閲覧可）
```

## 📂 構成

```
news-dashboard/
├── config/
│   ├── sources.json    # RSSフィード一覧
│   ├── topics.json     # 単元定義（14カテゴリ・キーワード）
│   └── api.json        # LLMバックエンド設定
├── data/
│   ├── raw/            # 日次取得した記事（JSON）
│   ├── topics/         # 単元別の累積記事履歴
│   └── summaries/      # 単元別AI要約（日次）
├── docs/               # 生成されたHTML（GitHub Pages公開対象）
│   ├── index.html
│   ├── robots.txt
│   └── topics/*.html
└── scripts/
    ├── fetch.ps1       # RSS取得
    ├── categorize.ps1  # キーワード分類
    ├── summarize.ps1   # LLM分類＋AI要約
    ├── generate.ps1    # HTML生成
    ├── run-daily.ps1   # 日次バッチ
    ├── llm-helper.ps1  # API/Claude Code共通呼び出し
    ├── setup-schedule.ps1  # タスクスケジューラ登録
    └── test-llm.ps1    # LLMバックエンド単体テスト
```

## 🚀 セットアップ

### 必要環境

- Windows 10/11
- PowerShell 5.1+ (標準搭載)
- Git
- Claude Code Desktop（Maxプラン推奨） または Anthropic API キー

### 初期設定

```powershell
# 1. このリポジトリをクローン
git clone https://github.com/YOUR-USERNAME/finance-news-dashboard.git
cd finance-news-dashboard

# 2. LLMバックエンド設定（config/api.json を編集）
# - "backend": "claude-code" → Maxプラン枠で実行（追加コスト$0）
# - "backend": "api" → Anthropic API（要 ANTHROPIC_API_KEY 環境変数）

# 3. 動作確認（手動実行）
powershell -ExecutionPolicy Bypass -File scripts\run-daily.ps1 -OpenAfter

# 4. 毎朝6:00自動実行を登録
powershell -ExecutionPolicy Bypass -File scripts\setup-schedule.ps1
```

## ⚙️ カスタマイズ

- **RSSソース追加**: `config/sources.json`
- **単元・キーワード調整**: `config/topics.json`
- **LLMモデル変更**: `config/api.json`（`opus`/`sonnet`/`haiku`）

## 🔒 セキュリティ

- APIキーは環境変数（`ANTHROPIC_API_KEY`）のみ。リポジトリには含まれません
- `logs/` は `.gitignore` で除外（ローカルパスを含むため）
- 公開リポジトリですが、収集する記事は全て公開RSSの転載のみ

## 📊 LLM呼び出しコスト

| バックエンド | 1日あたり | 備考 |
|---|---|---|
| Claude Code (Maxプラン) | **$0** | Maxプラン利用枠を消費（haikuで~17 calls/日） |
| Anthropic API (haiku) | ~$0.10 | プロンプトキャッシュ込み |
| Anthropic API (opus) | ~$0.50 | プロンプトキャッシュ込み |

## 📜 ライセンス

このコード自体はMIT。ニュース記事の著作権は各報道機関に帰属し、本サイトは見出し・概要・URLのみを表示する集約サイトです。
