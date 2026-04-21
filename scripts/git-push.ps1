#Requires -Version 5.1
<#
.SYNOPSIS
  生成された記事データ・要約・HTMLをGitHubにpushする
.NOTES
  - Git Credential Manager の認証情報（DPAPI暗号化）を使用するため、追加設定不要
  - PS 5.1 + 2>&1 + ErrorActionPreference=Stop の組み合わせは git の警告（CRLF等）を
    NativeCommandError として throw するため、git実行は cmd.exe 経由 + 終了コード判定で行う
#>
[CmdletBinding()]
param(
    [string]$Root = ''
)

# 注意: ErrorActionPreference は Continue にしておく（git警告で誤爆させないため）
$ErrorActionPreference = 'Continue'
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

# git 実行ラッパー: System.Diagnostics.Process で正しくクォート + stderrを分離
# (Start-Process は配列引数のスペース処理が不適切で commit メッセージ分割の原因になる)
function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)

    # スペース・引用符を含む引数は CommandLineToArgvW 互換でクォート
    $quoted = $Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }
    $argString = $quoted -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'git'
    $psi.Arguments              = $argString
    # Push-Location は .NET の CurrentDirectory を変えないため明示指定
    $psi.WorkingDirectory       = (Get-Location).Path
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    # 非同期読み取りでデッドロック回避（stderrが多量=CRLF警告でブロックする問題の対処）
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stdout = $outTask.Result
    $stderr = $errTask.Result

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

# Gitリポジトリかチェック
$gitDir = Join-Path $Root '.git'
if (-not (Test-Path $gitDir)) {
    Write-Log "Not a git repository: $Root (skip)" 'WARN'
    exit 0
}

Push-Location $Root
try {
    # 孤立した index.lock を除去（前回実行が異常終了した場合の回復）
    $lockFile = Join-Path $gitDir 'index.lock'
    if (Test-Path $lockFile) {
        $lockAge = ((Get-Date) - (Get-Item $lockFile).LastWriteTime).TotalSeconds
        # アクティブな git プロセスが無いかチェック
        $activeGit = Get-Process -Name 'git' -ErrorAction SilentlyContinue
        if (-not $activeGit -or $lockAge -gt 60) {
            Write-Log "孤立した index.lock を除去（経過 $([int]$lockAge)秒）" 'WARN'
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "index.lock が存在し、git プロセスも稼働中。待機します..." 'WARN'
            Start-Sleep -Seconds 5
            if (Test-Path $lockFile) {
                Write-Log "待機後もロック継続。強制除去" 'WARN'
                Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # remote確認
    $r = Invoke-Git @('config','--get','remote.origin.url')
    $remoteUrl = ($r.Stdout).Trim()
    if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
        Write-Log "No remote 'origin' configured (skip)" 'WARN'
        exit 0
    }
    Write-Log "Remote: $remoteUrl"

    # ステージング
    $r = Invoke-Git @('add','data/','docs/')
    if ($r.ExitCode -ne 0) {
        Write-Log "git add failed (exit $($r.ExitCode)): $($r.Stderr)" 'ERROR'
        exit 1
    }

    # 差分チェック
    $r = Invoke-Git @('diff','--cached','--name-only')
    $diff = ($r.Stdout).Trim()
    if ([string]::IsNullOrWhiteSpace($diff)) {
        Write-Log "No changes to commit"
        exit 0
    }
    $changeCount = ($diff -split "`n" | Where-Object { $_ } | Measure-Object).Count
    Write-Log "Staged $changeCount changed files"

    # コミット
    $commitMsg = "Auto-update: $Today daily run"
    $r = Invoke-Git @('commit','-m',$commitMsg)
    if ($r.ExitCode -ne 0) {
        Write-Log "git commit failed (exit $($r.ExitCode)): $($r.Stderr)" 'ERROR'
        exit 1
    }

    # Push
    Write-Log "Pushing to origin..."
    $r = Invoke-Git @('push','origin','main')
    if ($r.ExitCode -ne 0) {
        Write-Log "git push failed (exit $($r.ExitCode))" 'ERROR'
        Write-Log "  stderr: $($r.Stderr)" 'ERROR'
        exit 1
    }
    Write-Log "Push succeeded"
} finally {
    Pop-Location
}
