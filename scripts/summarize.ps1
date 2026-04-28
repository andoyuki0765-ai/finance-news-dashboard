#Requires -Version 5.1
<#
.SYNOPSIS
  Anthropic Claude APIで①未分類記事の分類②単元ごとの日次要約を生成
.NOTES
  ANTHROPIC_API_KEY環境変数が必要。未設定時はスキップ（システムは引き続き動作）
#>
[CmdletBinding()]
param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# $PSScriptRoot is the script's own directory; resolve $Root from there if not provided
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

. (Join-Path $PSScriptRoot 'llm-helper.ps1')

$ConfigPath    = Join-Path $Root 'config\api.json'
$TopicsConfig  = Join-Path $Root 'config\topics.json'
$RawDir        = Join-Path $Root 'data\raw'
$TopicsDir     = Join-Path $Root 'data\topics'
$SummariesDir  = Join-Path $Root 'data\summaries'
$LogDir        = Join-Path $Root 'logs'

if (-not (Test-Path $SummariesDir)) { New-Item -ItemType Directory -Path $SummariesDir -Force | Out-Null }

$Today    = Get-Date -Format 'yyyy-MM-dd'
$Last24h  = (Get-Date).AddHours(-24)
$LogFile  = Join-Path $LogDir "summarize-$Today.log"
$RawFile  = Join-Path $RawDir "$Today.json"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$stamp [$Level] $Message" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

# ===== 前提チェック =====
if (-not (Test-Path $ConfigPath)) {
    Write-Log "API config not found: $ConfigPath" 'ERROR'
    exit 1
}
$apiCfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $apiCfg.enabled) {
    Write-Log "API config の enabled が false。スキップします"
    exit 0
}

# バックエンドの可用性チェック
$backend = if ($apiCfg.backend) { $apiCfg.backend } else { 'api' }
switch ($backend) {
    'api' {
        if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY)) {
            Write-Log "backend=api だが ANTHROPIC_API_KEY が未設定。LLM機能をスキップします" 'WARN'
            Write-Log "  設定方法: setx ANTHROPIC_API_KEY 'sk-ant-...'  (新しいシェルから有効)"
            Write-Log "  または config/api.json の backend を 'claude-code' に変更"
            exit 0
        }
        Write-Log "Backend: Anthropic API (model=$($apiCfg.model))"
    }
    'claude-code' {
        # Logger経由でFind-ClaudeCodeExeの内部動作を記録（タスクスケジューラ環境でのデバッグ用）
        $findLogger = { param($m) Write-Log "  [Find-ClaudeCodeExe] $m" 'DEBUG' }
        $exePath = Find-ClaudeCodeExe -ExplicitPath $apiCfg.claude_code.path -Logger $findLogger
        if (-not $exePath) {
            Write-Log "backend=claude-code だが claude.exe が見つかりません。LLM処理をスキップします" 'ERROR'
            Write-Log "  config/api.json の claude_code.path に絶対パスを指定してください（現在: $($apiCfg.claude_code.path))" 'ERROR'
            exit 0  # graceful skip (次の世代はキーワード分類のみで続行)
        }

        # セルフヒーリング: 設定パスと違うものが見つかったら api.json を自動更新
        if ($apiCfg.claude_code.path -ne $exePath) {
            try {
                $apiCfg.claude_code.path = $exePath
                $apiCfg | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigPath -Encoding UTF8
                Write-Log "  [自動更新] api.json の claude_code.path を更新: $exePath"
            } catch {
                Write-Log "  [WARN] api.json 自動更新失敗（ReadOnly?）: $($_.Exception.Message)" 'WARN'
            }
        }

        Write-Log "Backend: Claude Code CLI (path=$exePath, model=$($apiCfg.claude_code.model))"
    }
    default {
        Write-Log "Unknown backend: $backend" 'ERROR'
        exit 1
    }
}

if (-not (Test-Path $RawFile)) {
    Write-Log "Raw file not found: $RawFile" 'ERROR'
    exit 1
}

$topicsConf = Get-Content $TopicsConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$rawData    = Get-Content $RawFile -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Log "LLM処理開始 articles=$($rawData.articles.Count)"

# ===== Phase 1: 未分類記事のLLM分類 =====
# 既に単元ファイルに含まれているURLを集める
$allCategorizedUrls = New-Object System.Collections.Generic.HashSet[string]
$topicData = @{}
foreach ($t in $topicsConf.topics) {
    $file = Join-Path $TopicsDir "$($t.id).json"
    if (Test-Path $file) {
        $topicData[$t.id] = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($a in $topicData[$t.id].articles) {
            [void]$allCategorizedUrls.Add($a.url)
        }
    }
}

$uncategorized = @($rawData.articles | Where-Object { -not $allCategorizedUrls.Contains($_.url) })
Write-Log "未分類記事: $($uncategorized.Count) 件"

if ($uncategorized.Count -gt 0) {
    # トピック一覧をシステムプロンプトに（キャッシュ対象）
    $topicListText = ($topicsConf.topics | ForEach-Object {
        "- {0} (id: {1}): {2}" -f $_.name, $_.id, $_.description
    }) -join "`n"

    $classifySystem = @"
あなたは日本の金融・経済ニュースの分類担当です。記事のタイトルと概要から、以下の単元のどれに属するかを判定してください。

【単元一覧】
$topicListText

【判定ルール】
- 1つの記事は最も関連性の高い1つの単元に分類してください
- どの単元にも明確に該当しない場合は "other" を返してください
- 政治・芸能・スポーツなど金融経済と無関係なものは "other" を返してください

【出力形式】
必ず以下のJSON形式のみを返してください（前後の説明文は不要）：
{"results":[{"index":0,"topic_id":"monetary-policy"},{"index":1,"topic_id":"other"}]}
"@

    # 30件ずつバッチ処理（コンテキスト爆発防止）
    $batchSize = 30
    $allClassifications = @()
    for ($i = 0; $i -lt $uncategorized.Count; $i += $batchSize) {
        $batch = $uncategorized[$i..([Math]::Min($i + $batchSize - 1, $uncategorized.Count - 1))]
        $articleListText = ($batch | ForEach-Object -Begin { $idx = 0 } -Process {
            $line = "[{0}] タイトル: {1}" -f $idx, $_.title
            if ($_.description) {
                $desc = $_.description
                if ($desc.Length -gt 200) { $desc = $desc.Substring(0, 200) + '…' }
                $line += "`n    概要: $desc"
            }
            $idx++
            $line
        }) -join "`n`n"

        $userMsg = "以下の記事を分類してください：`n`n$articleListText"
        Write-Log "  分類LLM呼び出し: $($batch.Count) 件 (batch $([Math]::Floor($i / $batchSize) + 1))"

        $resp = Invoke-LLM -Config $apiCfg `
            -SystemPrompt $classifySystem -UserMessage $userMsg `
            -MaxTokens $apiCfg.max_tokens_classify

        if (-not $resp.Success) {
            Write-Log "  分類失敗: $($resp.Error)" 'WARN'
            continue
        }

        # API使用量ログ（apiバックエンドのみ）
        if ($resp.Usage -and $resp.Backend -eq 'api') {
            $cr = $resp.Usage.cache_read_input_tokens
            $cw = $resp.Usage.cache_creation_input_tokens
            Write-Log "  usage: input=$($resp.Usage.input_tokens) output=$($resp.Usage.output_tokens) cache_read=$cr cache_write=$cw"
        }

        # JSONパース（Claudeが余計な文字を返した場合に備えて抽出）
        $jsonText = $resp.Text
        if ($jsonText -match '\{[\s\S]*\}') {
            $jsonText = $matches[0]
        }
        try {
            $parsed = $jsonText | ConvertFrom-Json
            foreach ($r in $parsed.results) {
                $globalIdx = $i + $r.index
                if ($globalIdx -lt $uncategorized.Count) {
                    $allClassifications += [pscustomobject]@{
                        article  = $uncategorized[$globalIdx]
                        topic_id = $r.topic_id
                    }
                }
            }
        } catch {
            Write-Log "  JSONパース失敗: $($_.Exception.Message)" 'WARN'
        }
    }

    # 単元データに追加
    $addedCount = @{}
    foreach ($c in $allClassifications) {
        if ($c.topic_id -eq 'other' -or [string]::IsNullOrWhiteSpace($c.topic_id)) { continue }
        if (-not $topicData.ContainsKey($c.topic_id)) { continue }

        $entry = [pscustomobject]@{
            source       = $c.article.source
            title        = $c.article.title
            url          = $c.article.url
            description  = $c.article.description
            publishedAt  = $c.article.publishedAt
            fetchedAt    = $c.article.fetchedAt
            matchKeyword = '[LLM分類]'
        }
        $topicData[$c.topic_id].articles = @($topicData[$c.topic_id].articles) + $entry
        if (-not $addedCount.ContainsKey($c.topic_id)) { $addedCount[$c.topic_id] = 0 }
        $addedCount[$c.topic_id]++
    }

    foreach ($tid in $addedCount.Keys) {
        # 公開日順にソートして上限1000件で切る
        $sorted = @($topicData[$tid].articles |
            Sort-Object -Property @{Expression={ if ($_.publishedAt) { [DateTime]::Parse($_.publishedAt) } else { [DateTime]::MinValue } }; Descending=$true})
        if ($sorted.Count -gt 1000) { $sorted = $sorted[0..999] }
        $topicData[$tid].articles = $sorted

        $file = Join-Path $TopicsDir "$tid.json"
        $topicData[$tid] | ConvertTo-Json -Depth 6 | Out-File -FilePath $file -Encoding UTF8
        Write-Log "  → '$tid' に $($addedCount[$tid]) 件追加（LLM分類）"
    }
}

# ===== Phase 2: 単元ごとの日次要約 =====
$summarySystem = @"
あなたは日本の金融市場アナリストです。指定された単元について、本日の動きと過去からの文脈をまとめた日本語のレポートを作成してください。

【出力形式】
必ず以下のJSON形式のみを返してください（前後の説明文・コードフェンス不要）：
{
  "today": "本日の主な動きを2-3文で。具体的な数値・固有名詞を含める。",
  "context": "過去1週間の流れの中での位置づけを2-3文で。トレンドや変化点に言及。",
  "watch": "明日以降の注目点を1-2文で。次に何を確認すべきか。",
  "sentiment": "positive | negative | neutral | mixed のいずれか",
  "headline": "本日の動きを表す10-20文字の見出し",
  "irrelevant_indices": [この単元に明らかに無関係な記事のインデックス番号を配列で。なければ []]
}

【執筆ルール】
- 中立的・事実ベース。煽り表現や予想は避ける
- 一次情報の出典は記事タイトルにあるので冗長な引用は不要
- 単元と無関係な記事（例: スポーツ、芸能、雑学など）は要約から除外し、必ず irrelevant_indices にそのインデックスを記載

【無関係判定の例】
- 「制裁」キーワードでヒットしたがプロレスや格闘技の試合内容 → 地政学・通商と無関係
- 「金」キーワードでヒットしたが芸能ニュース → 商品市況と無関係
- 「FRB」キーワードでヒットしたが個人ブログ的なコラム → 金融政策と無関係（ニュース性なし）
"@

$generatedCount = 0
$skippedCount = 0
$failedCount = 0

foreach ($t in $topicsConf.topics) {
    if (-not $topicData.ContainsKey($t.id)) { continue }
    $articles = @($topicData[$t.id].articles)

    # 24時間以内の記事
    $newOnes = @($articles | Where-Object {
        if ($_.publishedAt) {
            try { [DateTime]::Parse($_.publishedAt) -ge $Last24h } catch { $false }
        } else { $false }
    })
    if ($newOnes.Count -eq 0) {
        $skippedCount++
        continue
    }

    # 1日4回配信のため毎回再生成（同日内でも上書き）
    $summaryFile = Join-Path $SummariesDir "$($t.id)-$Today.json"

    # 過去N日間の見出し（コンテキスト用）
    $historyCutoff = (Get-Date).AddDays(-$apiCfg.history_days_in_context)
    $history = @($articles | Where-Object {
        if ($_.publishedAt) {
            try {
                $dt = [DateTime]::Parse($_.publishedAt)
                ($dt -ge $historyCutoff) -and ($dt -lt $Last24h)
            } catch { $false }
        } else { $false }
    } | Select-Object -First $apiCfg.max_history_headlines)

    # 本日記事リスト構築（インデックス付き — irrelevant判定用）
    $maxArticles = $apiCfg.max_articles_per_summary
    $todayBatch = @($newOnes | Select-Object -First $maxArticles)
    $idx = 0
    $todayList = ($todayBatch | ForEach-Object {
        $line = "[{0}] ・{1}" -f $idx, $_.title
        if ($_.description) {
            $d = $_.description
            if ($d.Length -gt 150) { $d = $d.Substring(0, 150) + '…' }
            $line += " — $d"
        }
        $idx++
        $line
    }) -join "`n"

    $historyList = if ($history.Count -gt 0) {
        ($history | ForEach-Object {
            $dateStr = if ($_.publishedAt) { try { [DateTime]::Parse($_.publishedAt).ToString('M/d') } catch { '?' } } else { '?' }
            "[$dateStr] $($_.title)"
        }) -join "`n"
    } else {
        '（過去履歴なし）'
    }

    $userMsg = @"
【単元】$($t.name)
【単元の説明】$($t.description)

【本日（直近24時間）の記事 $($newOnes.Count)件】
$todayList

【過去$($apiCfg.history_days_in_context)日間の見出し】
$historyList

上記を基に、JSON形式でレポートを生成してください。
"@

    Write-Log "  $($t.icon) $($t.name): LLM呼び出し中... (本日$($newOnes.Count)件、履歴$($history.Count)件)"

    $resp = Invoke-LLM -Config $apiCfg `
        -SystemPrompt $summarySystem -UserMessage $userMsg `
        -MaxTokens $apiCfg.max_tokens_summary

    if (-not $resp.Success) {
        Write-Log "    失敗: $($resp.Error)" 'WARN'
        $failedCount++
        continue
    }

    if ($resp.Usage -and $resp.Backend -eq 'api') {
        $cr = $resp.Usage.cache_read_input_tokens
        $cw = $resp.Usage.cache_creation_input_tokens
        Write-Log "    usage: input=$($resp.Usage.input_tokens) output=$($resp.Usage.output_tokens) cache_read=$cr cache_write=$cw"
    }

    # JSON抽出（コードフェンスや余計な文字に対応）
    $jsonText = $resp.Text
    if ($jsonText -match '\{[\s\S]*\}') {
        $jsonText = $matches[0]
    }

    try {
        $parsed = $jsonText | ConvertFrom-Json
    } catch {
        Write-Log "    JSONパース失敗、生テキストとして保存: $($_.Exception.Message)" 'WARN'
        $parsed = [pscustomobject]@{
            today     = $resp.Text
            context   = ''
            watch     = ''
            sentiment = 'neutral'
            headline  = ''
        }
    }

    # ===== 無関係記事の自動除外 =====
    if ($parsed.PSObject.Properties.Name -contains 'irrelevant_indices' -and $parsed.irrelevant_indices) {
        $irrelevantUrls = New-Object System.Collections.Generic.HashSet[string]
        foreach ($idx in $parsed.irrelevant_indices) {
            try {
                $i = [int]$idx
                if ($i -ge 0 -and $i -lt $todayBatch.Count) {
                    [void]$irrelevantUrls.Add($todayBatch[$i].url)
                    Write-Log "    [除外] LLMが無関係と判定: $($todayBatch[$i].title.Substring(0, [Math]::Min(40, $todayBatch[$i].title.Length)))..." 'WARN'
                }
            } catch {}
        }
        if ($irrelevantUrls.Count -gt 0) {
            $beforeCount = @($topicData[$t.id].articles).Count
            $topicData[$t.id].articles = @($topicData[$t.id].articles | Where-Object { -not $irrelevantUrls.Contains($_.url) })
            $removedCount = $beforeCount - @($topicData[$t.id].articles).Count
            # 単元ファイル更新
            $tFile = Join-Path $TopicsDir "$($t.id).json"
            $topicData[$t.id] | ConvertTo-Json -Depth 6 | Out-File -FilePath $tFile -Encoding UTF8
            Write-Log "    → $($t.name) から $removedCount 件除外 (累計 $beforeCount → $(@($topicData[$t.id].articles).Count))"
            # newOnes も再計算（新規件数を正しく報告するため）
            $newOnes = @($topicData[$t.id].articles | Where-Object {
                if ($_.publishedAt) { try { [DateTime]::Parse($_.publishedAt) -ge $Last24h } catch { $false } } else { $false }
            })
        }
    }

    $modelUsed = if ($backend -eq 'claude-code') { "Claude Code ($($apiCfg.claude_code.model))" } else { $apiCfg.model }
    $summaryObj = [pscustomobject]@{
        topic_id          = $t.id
        topic_name        = $t.name
        date              = $Today
        generated_at      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        backend           = $backend
        model             = $modelUsed
        new_article_count = $newOnes.Count
        history_count     = $history.Count
        headline          = $parsed.headline
        today             = $parsed.today
        context           = $parsed.context
        watch             = $parsed.watch
        sentiment         = $parsed.sentiment
    }

    $summaryObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $summaryFile -Encoding UTF8
    Write-Log "    → 保存: $summaryFile"
    $generatedCount++
}

Write-Log "完了: 生成 $generatedCount 件 / スキップ $skippedCount 件 / 失敗 $failedCount 件"
