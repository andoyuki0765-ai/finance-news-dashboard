#Requires -Version 5.1
<#
.SYNOPSIS
  本日のAIサマリをまとめてGmailで自分宛に送信
.NOTES
  - DPAPI暗号化された認証情報を一時的にメモリ上で復号
  - SMTP送信後、認証情報はGCで破棄
  - パスワードは平文ファイル・環境変数・ログのいずれにも書きません
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$TestOnly,
    [string]$DashboardUrl = 'https://andoyuki0765-ai.github.io/finance-news-dashboard/output/'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

$TopicsConfig = Join-Path $Root 'config\topics.json'
$SummariesDir = Join-Path $Root 'data\summaries'
$LogDir       = Join-Path $Root 'logs'

$Today    = Get-Date -Format 'yyyy-MM-dd'
$TodayJp  = Get-Date -Format 'yyyy年M月d日(ddd)'
$LogFile  = Join-Path $LogDir "send-email-$Today.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$stamp [$Level] $Message" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

# ===== 認証情報の読み込み =====
$CredFile = Join-Path $env:USERPROFILE '.news-dashboard\smtp.xml'
if (-not (Test-Path $CredFile)) {
    Write-Log "認証情報なし。先に setup-smtp.ps1 を実行してください: $CredFile" 'ERROR'
    Write-Log "  実行: powershell -File scripts\setup-smtp.ps1"
    exit 1
}

try {
    $cred = Import-Clixml -Path $CredFile
} catch {
    Write-Log "認証情報の復号に失敗: $($_.Exception.Message)" 'ERROR'
    Write-Log "  別ユーザーまたは別マシンでは復号できません。setup-smtp.ps1 を再実行してください"
    exit 1
}
$emailAddr = $cred.UserName

# ===== サマリの収集 =====
$topicsConf = Get-Content $TopicsConfig -Raw -Encoding UTF8 | ConvertFrom-Json

$summaries = New-Object System.Collections.Generic.List[object]
foreach ($t in $topicsConf.topics) {
    $f = Join-Path $SummariesDir "$($t.id)-$Today.json"
    if (Test-Path $f) {
        try {
            $s = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
            $summaries.Add([pscustomobject]@{
                Icon      = $t.icon
                Name      = $t.name
                Headline  = $s.headline
                Today     = $s.today
                Sentiment = $s.sentiment
                NewCount  = $s.new_article_count
                Url       = "$DashboardUrl" + "topics/$($t.id).html"
            }) | Out-Null
        } catch {
            Write-Log "  $($t.name): サマリJSON読み込み失敗（スキップ）" 'WARN'
        }
    }
}

if ($summaries.Count -eq 0) {
    Write-Log "本日のサマリがありません。メール送信スキップ" 'WARN'
    exit 0
}

Write-Log "本日のサマリ $($summaries.Count) 件をメール送信準備中"

# ===== メール本文生成（プレーンテキスト） =====
function Get-SentimentMark { param($s)
    switch ($s) {
        'positive' { '🟢' }
        'negative' { '🔴' }
        'mixed'    { '🟡' }
        default    { '⚪' }
    }
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("おはようございます。$TodayJp の金融ニュースダイジェストです。")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("📊 本日の動き（$($summaries.Count)単元）")
[void]$sb.AppendLine(("=" * 50))
[void]$sb.AppendLine("")

foreach ($s in $summaries) {
    $mark = Get-SentimentMark $s.Sentiment
    [void]$sb.AppendLine("$mark $($s.Icon) 【$($s.Name)】 $($s.Headline)")
    if ($s.Today) {
        [void]$sb.AppendLine("    $($s.Today)")
    }
    [void]$sb.AppendLine("    🔗 $($s.Url)")
    [void]$sb.AppendLine("    （新規 $($s.NewCount)件）")
    [void]$sb.AppendLine("")
}

[void]$sb.AppendLine(("=" * 50))
[void]$sb.AppendLine("")
[void]$sb.AppendLine("📱 ダッシュボード全体（モバイル対応）")
[void]$sb.AppendLine("$DashboardUrl")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("このメールは自動生成されています")
[void]$sb.AppendLine("生成: $((Get-Date).ToString('yyyy/MM/dd HH:mm'))")
[void]$sb.AppendLine("送信を停止する場合: scripts\setup-smtp.ps1 -Remove")

$body = $sb.ToString()

# ===== サブジェクト =====
$posCount = ($summaries | Where-Object { $_.Sentiment -eq 'positive' }).Count
$negCount = ($summaries | Where-Object { $_.Sentiment -eq 'negative' }).Count
$subject  = "📊 金融ニュース日次サマリ - $TodayJp（🟢$posCount / 🔴$negCount）"

if ($TestOnly) {
    Write-Log "===== TEST MODE: 送信せず内容のみ表示 ====="
    Write-Host ""
    Write-Host "From   : $emailAddr"
    Write-Host "To     : $emailAddr"
    Write-Host "Subject: $subject"
    Write-Host ""
    Write-Host $body
    Write-Host ""
    Write-Log "===== TEST MODE 完了 ====="
    return
}

# ===== SMTP送信 =====
try {
    Write-Log "SMTP送信開始: $emailAddr → $emailAddr"

    # PSCredentialからUTF-8 SMTPメッセージを送信
    # Send-MailMessage は非推奨警告が出るが、PS5.1で確実に動く方法
    $oldWarning = $WarningPreference
    $WarningPreference = 'SilentlyContinue'

    Send-MailMessage `
        -SmtpServer 'smtp.gmail.com' `
        -Port 587 `
        -UseSsl `
        -Credential $cred `
        -From $emailAddr `
        -To $emailAddr `
        -Subject $subject `
        -Body $body `
        -Encoding ([System.Text.Encoding]::UTF8)

    $WarningPreference = $oldWarning

    Write-Log "送信成功"
} catch {
    Write-Log "送信失敗: $($_.Exception.Message)" 'ERROR'
    if ($_.Exception.Message -match 'authentication|5\.7\.|invalid') {
        Write-Log "  → アプリパスワードが無効の可能性。setup-smtp.ps1 を再実行してください"
    }
    exit 1
} finally {
    # 認証情報を明示的に破棄
    $cred = $null
    [System.GC]::Collect()
}
