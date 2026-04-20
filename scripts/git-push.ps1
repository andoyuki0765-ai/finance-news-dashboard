#Requires -Version 5.1
<#
.SYNOPSIS
  生成された記事データ・要約・HTMLをGitHubにpushする
.NOTES
  Git Credential Manager の認証情報（DPAPI暗号化）を使用するため、追加設定不要
#>
[CmdletBinding()]
param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

$Today   = Get-Date -Format 'yyyy-MM-dd'
$LogDir  = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir "git-push-$Today.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$stamp [$Level] $Message" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

# Gitリポジトリかチェック
$gitDir = Join-Path $Root '.git'
if (-not (Test-Path $gitDir)) {
    Write-Log "Not a git repository: $Root (skip)" 'WARN'
    exit 0
}

Push-Location $Root
try {
    # remoteが設定されているかチェック
    $remoteUrl = git config --get remote.origin.url 2>$null
    if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
        Write-Log "No remote 'origin' configured (skip)" 'WARN'
        exit 0
    }
    Write-Log "Remote: $remoteUrl"

    # 変更ファイルをステージング（生成物のみ。logsは.gitignore除外）
    git add data/ output/ 2>&1 | Out-Null

    # 差分があるかチェック
    $diff = git diff --cached --name-only 2>&1
    if ([string]::IsNullOrWhiteSpace($diff)) {
        Write-Log "No changes to commit"
        exit 0
    }

    $changeCount = ($diff -split "`n" | Where-Object { $_ } | Measure-Object).Count
    Write-Log "Staged $changeCount changed files"

    # コミット
    $commitMsg = "Auto-update: $Today daily run"
    git commit -m $commitMsg 2>&1 | ForEach-Object { Write-Log "  $_" }

    # Push
    Write-Log "Pushing to origin..."
    $pushResult = git push origin main 2>&1
    foreach ($line in $pushResult) {
        Write-Log "  $line"
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Log "Push failed with exit code $LASTEXITCODE" 'ERROR'
        exit 1
    }

    Write-Log "Push succeeded"
} finally {
    Pop-Location
}
