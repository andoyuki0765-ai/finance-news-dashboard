#Requires -Version 5.1
<#
.SYNOPSIS
  本日取得した記事を単元別に分類し、過去履歴とマージする
#>
[CmdletBinding()]
param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }

$TopicsConfig = Join-Path $Root 'config\topics.json'
$RawDir       = Join-Path $Root 'data\raw'
$TopicsDir    = Join-Path $Root 'data\topics'
$LogDir       = Join-Path $Root 'logs'

if (-not (Test-Path $TopicsDir)) { New-Item -ItemType Directory -Path $TopicsDir -Force | Out-Null }

$Today   = Get-Date -Format 'yyyy-MM-dd'
$LogFile = Join-Path $LogDir "categorize-$Today.log"
$RawFile = Join-Path $RawDir "$Today.json"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$stamp [$Level] $Message" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

if (-not (Test-Path $RawFile)) {
    Write-Log "Raw file not found: $RawFile" 'ERROR'
    exit 1
}

$topicsConf = Get-Content $TopicsConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$raw        = Get-Content $RawFile -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Log "Categorizing $($raw.articles.Count) articles into $($topicsConf.topics.Count) topics"

# 各単元ごとに本日記事を抽出
$matchCounts = @{}
foreach ($t in $topicsConf.topics) { $matchCounts[$t.id] = 0 }
$uncategorizedCount = 0

# 単元データを読み込み（無ければ初期化）、URL重複を防ぐためのインデックスを作成
$topicData = @{}
$topicSeen = @{}
foreach ($t in $topicsConf.topics) {
    $file = Join-Path $TopicsDir "$($t.id).json"
    if (Test-Path $file) {
        $topicData[$t.id] = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $topicData[$t.id] = [pscustomobject]@{
            id          = $t.id
            name        = $t.name
            icon        = $t.icon
            description = $t.description
            articles    = @()
        }
    }
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($a in $topicData[$t.id].articles) { [void]$set.Add($a.url) }
    $topicSeen[$t.id] = $set
}

foreach ($article in $raw.articles) {
    $haystack = ($article.title + ' ' + $article.description).ToLower()
    $matched = $false
    foreach ($t in $topicsConf.topics) {
        foreach ($kw in $t.keywords) {
            if ($haystack.Contains($kw.ToLower())) {
                if ($topicSeen[$t.id].Add($article.url)) {
                    # 新しいオブジェクトを構築して追加
                    $entry = [pscustomobject]@{
                        source       = $article.source
                        title        = $article.title
                        url          = $article.url
                        description  = $article.description
                        publishedAt  = $article.publishedAt
                        fetchedAt    = $article.fetchedAt
                        matchKeyword = $kw
                    }
                    $topicData[$t.id].articles = @($topicData[$t.id].articles) + $entry
                    $matchCounts[$t.id]++
                }
                $matched = $true
                break  # 同一単元内では1キーワードヒットで十分
            }
        }
    }
    if (-not $matched) { $uncategorizedCount++ }
}

# ファイルに保存（公開日の新しい順にソート、最大1000件まで保持）
foreach ($t in $topicsConf.topics) {
    $sorted = @($topicData[$t.id].articles |
        Sort-Object -Property @{Expression={ if ($_.publishedAt) { [DateTime]::Parse($_.publishedAt) } else { [DateTime]::MinValue } }; Descending=$true})
    if ($sorted.Count -gt 1000) { $sorted = $sorted[0..999] }
    $topicData[$t.id].articles = $sorted

    $file = Join-Path $TopicsDir "$($t.id).json"
    $topicData[$t.id] | ConvertTo-Json -Depth 6 | Out-File -FilePath $file -Encoding UTF8
    Write-Log "  $($t.icon) $($t.name): 新規 $($matchCounts[$t.id])件 / 累計 $($sorted.Count)件"
}

Write-Log "Uncategorized: $uncategorizedCount articles"
Write-Log "Categorize done."
