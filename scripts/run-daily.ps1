#Requires -Version 5.1
<#
.SYNOPSIS
  日次バッチ：取得 → 分類 → HTML生成 を一気通貫で実行
#>
[CmdletBinding()]
param(
    [switch]$OpenAfter
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root      = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ScriptDir = Join-Path $Root 'scripts'
$Today     = Get-Date -Format 'yyyy-MM-dd'
$LogDir    = Join-Path $Root 'logs'
$LogFile   = Join-Path $LogDir "run-$Today.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$stamp [$Level] $Message" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

Write-Log "=========================================="
Write-Log "Daily run start: $Today"
Write-Log "=========================================="

# ===== ネットワーク接続待機（PCスリープ復帰直後対策） =====
# タスクスケジューラがウェイク直後に起動するとDNS未確立で全fetchが失敗するため、
# 起動時にgithub.comへの到達確認をして最大2分待機する
Write-Log "ネットワーク接続を確認中..."
$netReady = $false
for ($i = 1; $i -le 24; $i++) {
    try {
        $r = Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -lt 400) {
            $netReady = $true
            Write-Log "ネットワーク到達可能 (試行 $i)"
            break
        }
    } catch {
        if ($i -eq 1) { Write-Log "  接続待機中... (DNS未確立の可能性、5秒間隔で最大2分試行)" 'WARN' }
    }
    Start-Sleep -Seconds 5
}
if (-not $netReady) {
    Write-Log "2分間ネットワーク到達せず。とりあえず処理続行（各stepでさらにリトライ）" 'WARN'
}

$steps = @(
    @{ Name = 'Fetch';      Script = 'fetch.ps1' }
    @{ Name = 'Categorize'; Script = 'categorize.ps1' }
    @{ Name = 'Summarize';  Script = 'summarize.ps1' }
    @{ Name = 'Generate';   Script = 'generate.ps1' }
    @{ Name = 'GitPush';    Script = 'git-push.ps1' }
    @{ Name = 'SendEmail';  Script = 'send-email.ps1' }
)

foreach ($step in $steps) {
    Write-Log ">>> Step: $($step.Name)"
    $scriptPath = Join-Path $ScriptDir $step.Script
    try {
        & $scriptPath
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Step $($step.Name) exited with code $LASTEXITCODE" }
        Write-Log "<<< Step $($step.Name) succeeded"
    } catch {
        Write-Log "Step $($step.Name) failed: $($_.Exception.Message)" 'ERROR'
        exit 1
    }
}

$indexHtml = Join-Path $Root 'docs\index.html'
Write-Log "Daily run complete. Dashboard: $indexHtml"

if ($OpenAfter -and (Test-Path $indexHtml)) {
    Start-Process $indexHtml
}
