#Requires -Version 5.1
<#
.SYNOPSIS
  単元別ダッシュボードと総合インデックスのHTMLを生成する
#>
[CmdletBinding()]
param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }

$TopicsConfig = Join-Path $Root 'config\topics.json'
$TopicsDir    = Join-Path $Root 'data\topics'
$SummariesDir = Join-Path $Root 'data\summaries'
$OutDir       = Join-Path $Root 'docs'
$OutTopicsDir = Join-Path $OutDir 'topics'
$LogDir       = Join-Path $Root 'logs'

if (-not (Test-Path $OutTopicsDir)) { New-Item -ItemType Directory -Path $OutTopicsDir -Force | Out-Null }

$Today   = Get-Date -Format 'yyyy-MM-dd'
$NowStr  = Get-Date -Format 'yyyy/MM/dd HH:mm'
$LogFile = Join-Path $LogDir "generate-$Today.log"
$Last24h = (Get-Date).AddHours(-24)

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$stamp [INFO] $Message" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

function HtmlEncode {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return [System.Web.HttpUtility]::HtmlEncode($s)
}
Add-Type -AssemblyName System.Web

function Get-RelativeTime {
    param([DateTime]$dt)
    $diff = (Get-Date) - $dt
    if ($diff.TotalMinutes -lt 60)  { return "$([int]$diff.TotalMinutes)分前" }
    if ($diff.TotalHours   -lt 24)  { return "$([int]$diff.TotalHours)時間前" }
    if ($diff.TotalDays    -lt 7)   { return "$([int]$diff.TotalDays)日前" }
    if ($diff.TotalDays    -lt 30)  { return "$([int]($diff.TotalDays/7))週間前" }
    if ($diff.TotalDays    -lt 365) { return "$([int]($diff.TotalDays/30))ヶ月前" }
    return "$([int]($diff.TotalDays/365))年前"
}

# ---- 共通CSS ----
$commonCss = @'
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Hiragino Kaku Gothic ProN","Yu Gothic Medium","メイリオ",sans-serif;background:#0f1115;color:#e6e8ec;line-height:1.6}
a{color:inherit;text-decoration:none}
a:hover{opacity:.8}
.container{max-width:1280px;margin:0 auto;padding:24px}
header{padding:24px 0 16px;border-bottom:1px solid #232732;margin-bottom:32px}
.header-inner{display:flex;justify-content:space-between;align-items:flex-end;flex-wrap:wrap;gap:12px}
h1{font-size:28px;font-weight:700;letter-spacing:.02em}
h1 .accent{color:#5eead4}
.meta{font-size:13px;color:#7d8595}
nav.crumbs{margin-bottom:16px;font-size:13px;color:#7d8595}
nav.crumbs a{color:#5eead4}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:16px}
.card{background:#161a23;border:1px solid #232732;border-radius:12px;padding:20px;transition:transform .15s,border-color .15s}
.card:hover{transform:translateY(-2px);border-color:#5eead4}
.card-icon{font-size:32px;margin-bottom:8px}
.card-title{font-size:18px;font-weight:600;margin-bottom:6px}
.card-desc{font-size:13px;color:#9ca3af;margin-bottom:14px;min-height:38px}
.card-stats{display:flex;gap:16px;font-size:12px;color:#7d8595;border-top:1px solid #232732;padding-top:12px}
.card-stats b{color:#5eead4;font-size:16px;font-weight:600;display:block}
.badge{display:inline-block;background:#1f2937;color:#5eead4;font-size:11px;padding:2px 8px;border-radius:999px;margin-left:6px}
.badge.new{background:#5eead4;color:#0f1115;font-weight:600}
.topic-header{display:flex;align-items:center;gap:16px;margin-bottom:8px}
.topic-icon{font-size:48px}
.topic-title{font-size:32px;font-weight:700}
.topic-desc{color:#9ca3af;margin-bottom:24px}
.section{margin-bottom:36px}
.section-title{font-size:18px;font-weight:600;margin-bottom:12px;padding-bottom:8px;border-bottom:2px solid #232732;display:flex;align-items:center;gap:8px}
.section-title .count{font-size:14px;color:#7d8595;font-weight:400}
.article{background:#161a23;border:1px solid #232732;border-radius:8px;padding:14px 16px;margin-bottom:8px;transition:border-color .15s}
.article:hover{border-color:#5eead4}
.article.is-new{border-left:3px solid #5eead4}
.article-title{font-size:15px;font-weight:500;margin-bottom:4px;color:#e6e8ec}
.article-meta{display:flex;gap:10px;font-size:12px;color:#7d8595;flex-wrap:wrap}
.article-source{color:#5eead4}
.article-desc{font-size:13px;color:#9ca3af;margin-top:6px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.timeline-group{margin-bottom:28px}
.timeline-date{font-size:13px;color:#7d8595;font-weight:600;margin-bottom:8px;padding-left:12px;border-left:3px solid #5eead4}
.chart-wrap{background:#161a23;border:1px solid #232732;border-radius:12px;padding:20px;margin-bottom:24px}
.chart-title{font-size:14px;color:#9ca3af;margin-bottom:12px}
canvas{max-height:200px}
.empty{text-align:center;color:#7d8595;padding:40px;background:#161a23;border:1px dashed #232732;border-radius:8px}
.ai-card{background:linear-gradient(135deg,#1a2332 0%,#161a23 100%);border:1px solid #5eead4;border-radius:12px;padding:24px;margin-bottom:32px;position:relative}
.ai-card::before{content:"🤖 AI日次レポート";position:absolute;top:-10px;left:16px;background:#5eead4;color:#0f1115;padding:2px 12px;font-size:11px;font-weight:600;border-radius:4px;letter-spacing:.05em}
.ai-headline{font-size:22px;font-weight:700;color:#fff;margin:8px 0 16px}
.ai-row{display:flex;gap:12px;margin-bottom:14px;align-items:flex-start}
.ai-label{flex-shrink:0;width:90px;font-size:12px;font-weight:600;color:#5eead4;padding-top:2px}
.ai-text{flex:1;font-size:14px;color:#e6e8ec;line-height:1.7}
.ai-meta{display:flex;justify-content:space-between;align-items:center;font-size:11px;color:#7d8595;margin-top:14px;padding-top:12px;border-top:1px solid #232732}
.sentiment{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:600}
.sentiment.positive{background:#064e3b;color:#6ee7b7}
.sentiment.negative{background:#4c1d24;color:#fca5a5}
.sentiment.neutral{background:#1f2937;color:#9ca3af}
.sentiment.mixed{background:#3f2e1a;color:#fbbf24}
.ai-snippet{font-size:12px;color:#9ca3af;margin-top:8px;font-style:italic;line-height:1.5}
footer{margin-top:48px;padding-top:24px;border-top:1px solid #232732;color:#7d8595;font-size:12px;text-align:center}
@media(max-width:600px){h1{font-size:22px}.topic-title{font-size:24px}.topic-icon{font-size:36px}}
'@

# ---- データ読み込み ----
$topicsConf = Get-Content $TopicsConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$topicSummaries = New-Object System.Collections.Generic.List[object]

foreach ($t in $topicsConf.topics) {
    $file = Join-Path $TopicsDir "$($t.id).json"
    if (-not (Test-Path $file)) {
        $topicSummaries.Add([pscustomobject]@{ id=$t.id; name=$t.name; icon=$t.icon; description=$t.description; total=0; today=0; latest=$null })
        continue
    }
    $data = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $articles = @($data.articles)

    $todayCount = 0
    foreach ($a in $articles) {
        if ($a.publishedAt) {
            try {
                $dt = [DateTime]::Parse($a.publishedAt)
                if ($dt -ge $Last24h) { $todayCount++ }
            } catch {}
        }
    }

    $latest = if ($articles.Count -gt 0 -and $articles[0].publishedAt) {
        try { [DateTime]::Parse($articles[0].publishedAt) } catch { $null }
    } else { $null }

    # 本日のAI要約を読み込み（存在すれば）
    $aiSummary = $null
    $summaryFile = Join-Path $SummariesDir "$($t.id)-$Today.json"
    if (Test-Path $summaryFile) {
        try { $aiSummary = Get-Content $summaryFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }

    $topicSummaries.Add([pscustomobject]@{
        id          = $t.id
        name        = $t.name
        icon        = $t.icon
        description = $t.description
        total       = $articles.Count
        today       = $todayCount
        latest      = $latest
        aiHeadline  = if ($aiSummary) { $aiSummary.headline } else { $null }
        aiSentiment = if ($aiSummary) { $aiSummary.sentiment } else { $null }
    })

    # ---- 単元別ダッシュボード生成 ----
    $sb = New-Object System.Text.StringBuilder

    # 過去30日間の日次本数を集計（チャート用）
    $dayBuckets = @{}
    for ($i = 0; $i -lt 30; $i++) {
        $d = (Get-Date).AddDays(-$i).ToString('yyyy-MM-dd')
        $dayBuckets[$d] = 0
    }
    foreach ($a in $articles) {
        if ($a.publishedAt) {
            try {
                $d = [DateTime]::Parse($a.publishedAt).ToString('yyyy-MM-dd')
                if ($dayBuckets.ContainsKey($d)) { $dayBuckets[$d]++ }
            } catch {}
        }
    }
    $chartLabels = ($dayBuckets.Keys | Sort-Object | ForEach-Object { '"' + $_ + '"' }) -join ','
    $chartData   = ($dayBuckets.Keys | Sort-Object | ForEach-Object { $dayBuckets[$_] }) -join ','

    # 記事を「24時間以内」「過去」に分割
    $newArticles = New-Object System.Collections.Generic.List[object]
    $oldArticles = New-Object System.Collections.Generic.List[object]
    foreach ($a in $articles) {
        $dt = if ($a.publishedAt) { try { [DateTime]::Parse($a.publishedAt) } catch { $null } } else { $null }
        if ($dt -and $dt -ge $Last24h) { $newArticles.Add($a) } else { $oldArticles.Add($a) }
    }

    [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>$(HtmlEncode $t.name) - 金融ニュースダッシュボード</title>
<style>$commonCss</style>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js" integrity="sha384-e6nUZLBkQ86NJ6TVVKAeSaK8jWa3NhkYWZFomE39AvDbQWeie9PlQqM3pmYW5d1g" crossorigin="anonymous"></script>
</head>
<body>
<div class="container">
<nav class="crumbs"><a href="../index.html">← ダッシュボード一覧</a></nav>
<header>
  <div class="topic-header">
    <div class="topic-icon">$($t.icon)</div>
    <div>
      <div class="topic-title">$(HtmlEncode $t.name)</div>
      <div class="meta">最終更新: $NowStr</div>
    </div>
  </div>
  <div class="topic-desc">$(HtmlEncode $t.description)</div>
</header>
"@)

    # AI日次レポートカード
    if ($aiSummary) {
        $sentClass = if ($aiSummary.sentiment) { $aiSummary.sentiment } else { 'neutral' }
        $sentLabel = switch ($sentClass) {
            'positive' { '🟢 ポジティブ' }
            'negative' { '🔴 ネガティブ' }
            'mixed'    { '🟡 まちまち' }
            default    { '⚪ ニュートラル' }
        }
        [void]$sb.Append(@"
<div class="ai-card">
  <div class="ai-headline">$(HtmlEncode $aiSummary.headline)</div>
  <div class="ai-row"><div class="ai-label">📍 本日の動き</div><div class="ai-text">$(HtmlEncode $aiSummary.today)</div></div>
  <div class="ai-row"><div class="ai-label">📈 過去の文脈</div><div class="ai-text">$(HtmlEncode $aiSummary.context)</div></div>
  <div class="ai-row"><div class="ai-label">👀 注目点</div><div class="ai-text">$(HtmlEncode $aiSummary.watch)</div></div>
  <div class="ai-meta">
    <span>本日$($aiSummary.new_article_count)件 / 過去$($aiSummary.history_count)件を分析 · $(HtmlEncode $aiSummary.model)</span>
    <span class="sentiment $sentClass">$sentLabel</span>
  </div>
</div>
"@)
    }

    [void]$sb.Append(@"

<div class="chart-wrap">
  <div class="chart-title">📊 過去30日間の記事本数推移</div>
  <canvas id="trendChart"></canvas>
</div>

<div class="section">
  <div class="section-title">🆕 直近24時間の動き <span class="count">$($newArticles.Count)件</span></div>
"@)

    if ($newArticles.Count -eq 0) {
        [void]$sb.Append('<div class="empty">直近24時間の新着記事はありません</div>')
    } else {
        foreach ($a in $newArticles) {
            $dt = if ($a.publishedAt) { try { [DateTime]::Parse($a.publishedAt) } catch { $null } } else { $null }
            $rel = if ($dt) { Get-RelativeTime $dt } else { '' }
            $kw = if ($a.matchKeyword) { '<span class="badge">' + (HtmlEncode $a.matchKeyword) + '</span>' } else { '' }
            [void]$sb.Append(@"
<a class="article is-new" href="$(HtmlEncode $a.url)" target="_blank" rel="noopener">
  <div class="article-title">$(HtmlEncode $a.title)</div>
  <div class="article-meta"><span class="article-source">$(HtmlEncode $a.source)</span><span>$rel</span>$kw</div>
"@)
            if ($a.description) { [void]$sb.Append('<div class="article-desc">' + (HtmlEncode $a.description) + '</div>') }
            [void]$sb.Append('</a>')
        }
    }
    [void]$sb.Append('</div>')

    # 過去履歴（日付ごとにグループ化）
    [void]$sb.Append('<div class="section"><div class="section-title">📚 過去からの変遷 <span class="count">' + $oldArticles.Count + '件</span></div>')
    if ($oldArticles.Count -eq 0) {
        [void]$sb.Append('<div class="empty">過去の記事はまだ蓄積されていません。明日以降の更新で増えていきます。</div>')
    } else {
        $grouped = $oldArticles | Group-Object -Property {
            if ($_.publishedAt) { try { [DateTime]::Parse($_.publishedAt).ToString('yyyy-MM-dd') } catch { '日付不明' } } else { '日付不明' }
        } | Sort-Object Name -Descending
        foreach ($g in $grouped) {
            [void]$sb.Append('<div class="timeline-group"><div class="timeline-date">' + (HtmlEncode $g.Name) + ' （' + $g.Count + '件）</div>')
            foreach ($a in $g.Group) {
                $kw = if ($a.matchKeyword) { '<span class="badge">' + (HtmlEncode $a.matchKeyword) + '</span>' } else { '' }
                [void]$sb.Append(@"
<a class="article" href="$(HtmlEncode $a.url)" target="_blank" rel="noopener">
  <div class="article-title">$(HtmlEncode $a.title)</div>
  <div class="article-meta"><span class="article-source">$(HtmlEncode $a.source)</span>$kw</div>
"@)
                if ($a.description) { [void]$sb.Append('<div class="article-desc">' + (HtmlEncode $a.description) + '</div>') }
                [void]$sb.Append('</a>')
            }
            [void]$sb.Append('</div>')
        }
    }
    [void]$sb.Append('</div>')

    [void]$sb.Append(@"
<footer>金融ニュースダッシュボード &middot; Powered by RSS &middot; $NowStr 生成</footer>
</div>
<script>
const ctx = document.getElementById('trendChart');
new Chart(ctx, {
  type: 'bar',
  data: {
    labels: [$chartLabels],
    datasets: [{
      label: '記事本数',
      data: [$chartData],
      backgroundColor: 'rgba(94, 234, 212, 0.6)',
      borderColor: 'rgba(94, 234, 212, 1)',
      borderWidth: 1
    }]
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    plugins: { legend: { display: false } },
    scales: {
      y: { beginAtZero: true, ticks: { color: '#7d8595' }, grid: { color: '#232732' } },
      x: { ticks: { color: '#7d8595', maxTicksLimit: 10 }, grid: { display: false } }
    }
  }
});
</script>
</body>
</html>
"@)

    $outFile = Join-Path $OutTopicsDir "$($t.id).html"
    $sb.ToString() | Out-File -FilePath $outFile -Encoding UTF8
    Write-Log "  Generated: $outFile"
}

# ---- インデックスページ生成 ----
$totalAll = ($topicSummaries | Measure-Object -Property total -Sum).Sum
$newAll   = ($topicSummaries | Measure-Object -Property today -Sum).Sum

$idx = New-Object System.Text.StringBuilder
[void]$idx.Append(@"
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>金融ニュースダッシュボード</title>
<style>$commonCss</style>
</head>
<body>
<div class="container">
<header>
  <div class="header-inner">
    <h1>📰 <span class="accent">金融</span>ニュースダッシュボード</h1>
    <div class="meta">最終更新: $NowStr ｜ 直近24h: <b style="color:#5eead4">$newAll件</b> ｜ 累計: $totalAll件</div>
  </div>
</header>
<div class="grid">
"@)

foreach ($s in $topicSummaries) {
    $newBadge = if ($s.today -gt 0) { '<span class="badge new">+' + $s.today + '</span>' } else { '' }
    $latestStr = if ($s.latest) { Get-RelativeTime $s.latest } else { '記事なし' }
    $cardDesc = if ($s.aiHeadline) {
        '<div class="card-desc"><b style="color:#5eead4">🤖 ' + (HtmlEncode $s.aiHeadline) + '</b></div>'
    } else {
        '<div class="card-desc">' + (HtmlEncode $s.description) + '</div>'
    }
    [void]$idx.Append(@"
<a class="card" href="topics/$($s.id).html">
  <div class="card-icon">$($s.icon)</div>
  <div class="card-title">$(HtmlEncode $s.name)$newBadge</div>
  $cardDesc
  <div class="card-stats">
    <div><b>$($s.today)</b>直近24h</div>
    <div><b>$($s.total)</b>累計</div>
    <div style="margin-left:auto;align-self:center">$latestStr</div>
  </div>
</a>
"@)
}

[void]$idx.Append(@"
</div>
<footer>金融ニュースダッシュボード &middot; Powered by RSS &middot; $NowStr 生成</footer>
</div>
</body>
</html>
"@)

$idxFile = Join-Path $OutDir 'index.html'
$idx.ToString() | Out-File -FilePath $idxFile -Encoding UTF8
Write-Log "Generated index: $idxFile"
Write-Log "Generate done. Topics: $($topicSummaries.Count), Total: $totalAll articles"
