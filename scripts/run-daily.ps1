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
