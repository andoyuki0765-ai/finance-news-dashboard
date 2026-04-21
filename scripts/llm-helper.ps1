#Requires -Version 5.1
<#
.SYNOPSIS
  Anthropic API / Claude Code CLI 共通の LLM 呼び出しヘルパー
#>

# ===== Anthropic API バックエンド =====
function Invoke-ClaudeAPI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserMessage,
        [int]$MaxTokens = 2048,
        [bool]$EnableCache = $true,
        [int]$TimeoutSec = 120
    )

    $headers = @{
        'x-api-key'         = $ApiKey
        'anthropic-version' = '2023-06-01'
        'content-type'      = 'application/json'
    }

    # システムプロンプトはキャッシュ対象（連続呼び出しで再利用）
    $systemBlock = if ($EnableCache) {
        @(@{
            type          = 'text'
            text          = $SystemPrompt
            cache_control = @{ type = 'ephemeral' }
        })
    } else {
        $SystemPrompt
    }

    $bodyObj = @{
        model      = $Model
        max_tokens = $MaxTokens
        system     = $systemBlock
        messages   = @(@{
            role    = 'user'
            content = $UserMessage
        })
    }

    $jsonBody = $bodyObj | ConvertTo-Json -Depth 10 -Compress
    $bytes    = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

    try {
        $response = Invoke-RestMethod `
            -Uri 'https://api.anthropic.com/v1/messages' `
            -Method Post `
            -Headers $headers `
            -Body $bytes `
            -ContentType 'application/json; charset=utf-8' `
            -TimeoutSec $TimeoutSec

        $textBlock = $response.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
        return [pscustomobject]@{
            Success = $true
            Text    = if ($textBlock) { $textBlock.text } else { '' }
            Usage   = $response.usage
            Backend = 'api'
        }
    } catch {
        $errMsg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errMsg = "$errMsg - $($_.ErrorDetails.Message)"
        }
        return [pscustomobject]@{
            Success = $false
            Text    = ''
            Error   = $errMsg
            Backend = 'api'
        }
    }
}

# ===== Claude Code CLI バックエンド =====
function Find-ClaudeCodeExe {
    [CmdletBinding()]
    param([string]$ExplicitPath = '')

    if ($ExplicitPath -and (Test-Path $ExplicitPath)) {
        return $ExplicitPath
    }

    # 探索を最大3回試行（Claude Codeアップデート中の一時的な未検出を回避）
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        # 優先1: PATHに通っている
        $cmd = Get-Command claude -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }

        # 優先2: AppData\Roaming\Claude\claude-code\<version>\claude.exe（最新版）
        $base = Join-Path $env:APPDATA 'Claude\claude-code'
        if (Test-Path $base) {
            # 全バージョンフォルダを新→旧の順に試す（最新版にclaude.exeが無くても次を試す）
            $versions = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                Sort-Object @{Expression={ try { [Version]$_.Name } catch { [Version]'0.0.0' } }} -Descending
            foreach ($v in $versions) {
                $exe = Join-Path $v.FullName 'claude.exe'
                if (Test-Path $exe) { return $exe }
            }
        }

        # アップデート中の可能性。少し待ってリトライ
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }

    return $null
}

function Invoke-ClaudeCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudePath,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserMessage,
        [int]$TimeoutSec = 180
    )

    if (-not (Test-Path $ClaudePath)) {
        return [pscustomobject]@{ Success=$false; Text=''; Error="Claude Code not found: $ClaudePath"; Backend='claude-code' }
    }

    # コマンドライン引数の長さ制限（Windows 32K）回避のため、systemプロンプトはファイル経由を試みる…が、
    # --system-prompt-file は CLI に存在しないため、--system-prompt インラインで渡す
    # 我々のシステムプロンプトは数KBなので問題ない

    # 一時的な空ディレクトリでclaudeを実行（CLAUDE.mdやプラグインの混入を防ぐ）
    $workDir = Join-Path $env:TEMP "claude-llm-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    # 出力を一時ファイルに（標準出力をUTF-8で取るため）
    $stdoutFile = Join-Path $workDir 'stdout.json'
    $stderrFile = Join-Path $workDir 'stderr.txt'
    $stdinFile  = Join-Path $workDir 'stdin.txt'

    try {
        # ユーザーメッセージをstdin経由で渡す（長文・特殊文字に強い）
        [System.IO.File]::WriteAllText($stdinFile, $UserMessage, [System.Text.UTF8Encoding]::new($false))

        # 全ツール無効化（純粋なテキスト生成のみ）
        $disallowedTools = 'Bash Edit Write Read Glob Grep WebFetch WebSearch Agent TodoWrite Task NotebookEdit Skill MultiEdit'

        # Windows用クォート: ダブルクォートを \" にエスケープし、全体を "" で囲む
        function QuoteArg([string]$s) {
            if ([string]::IsNullOrEmpty($s)) { return '""' }
            $escaped = $s -replace '\\', '\\' -replace '"', '\"'
            return '"' + $escaped + '"'
        }

        # システムプロンプトは長文なので一時ファイル経由が望ましいが、CLIに--system-prompt-fileがないためインライン
        $argString = (@(
            '-p',
            '--model',           (QuoteArg $Model),
            '--output-format',   'json',
            '--system-prompt',   (QuoteArg $SystemPrompt),
            '--disallowed-tools',(QuoteArg $disallowedTools),
            '--no-session-persistence'
        )) -join ' '

        # PowerShellでstdin入力 + 別プロセス起動 + リダイレクト
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $ClaudePath
        $psi.Arguments              = $argString
        $psi.WorkingDirectory       = $workDir
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        # stdinにUTF-8バイトで書き込む（PowerShell 5.1のStandardInputはシステムコードページなので
        # 日本語はそのまま書くと化ける。BaseStream経由でUTF-8バイトを直接流す）
        $stdinBytes = [System.Text.Encoding]::UTF8.GetBytes($UserMessage)
        $proc.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()

        # stdout/stderr非同期読み取り
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        # タイムアウト待ち
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $proc.Kill()
            return [pscustomobject]@{ Success=$false; Text=''; Error="Timeout after $TimeoutSec sec"; Backend='claude-code' }
        }

        $stdout = $outTask.Result
        $stderr = $errTask.Result
        $exitCode = $proc.ExitCode

        if ($exitCode -ne 0) {
            return [pscustomobject]@{
                Success = $false
                Text    = ''
                Error   = "Exit $exitCode. stderr: $stderr. stdout: $stdout"
                Backend = 'claude-code'
            }
        }

        # JSON出力をパース
        try {
            $result = $stdout | ConvertFrom-Json
            # Claude Code の --output-format json は { type, subtype, result, ... } を返す
            $text = if ($result.result) { $result.result } else { $stdout }
            return [pscustomobject]@{
                Success = $true
                Text    = $text
                Usage   = if ($result.usage) { $result.usage } else { $null }
                Backend = 'claude-code'
            }
        } catch {
            # JSONパース失敗時は生テキストとして返す
            return [pscustomobject]@{
                Success = $true
                Text    = $stdout
                Backend = 'claude-code'
            }
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Text    = ''
            Error   = $_.Exception.Message
            Backend = 'claude-code'
        }
    } finally {
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ===== ルーター =====
function Invoke-LLM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserMessage,
        [int]$MaxTokens = 2048
    )

    $backend = if ($Config.backend) { $Config.backend } else { 'api' }

    switch ($backend) {
        'claude-code' {
            $cc = $Config.claude_code
            $exePath = Find-ClaudeCodeExe -ExplicitPath $cc.path
            if (-not $exePath) {
                return [pscustomobject]@{
                    Success = $false; Text = ''; Backend = 'claude-code'
                    Error   = "Claude Code CLI が見つかりません。config/api.json の claude_code.path に絶対パスを指定してください"
                }
            }
            $timeout = if ($cc.timeout_sec) { $cc.timeout_sec } else { 180 }
            $model   = if ($cc.model) { $cc.model } else { 'opus' }
            return Invoke-ClaudeCode -ClaudePath $exePath -Model $model `
                -SystemPrompt $SystemPrompt -UserMessage $UserMessage -TimeoutSec $timeout
        }
        'api' {
            $apiKey = $env:ANTHROPIC_API_KEY
            if ([string]::IsNullOrWhiteSpace($apiKey)) {
                return [pscustomobject]@{
                    Success = $false; Text = ''; Backend = 'api'
                    Error   = 'ANTHROPIC_API_KEY 環境変数が未設定'
                }
            }
            return Invoke-ClaudeAPI -ApiKey $apiKey -Model $Config.model `
                -SystemPrompt $SystemPrompt -UserMessage $UserMessage -MaxTokens $MaxTokens
        }
        default {
            return [pscustomobject]@{
                Success = $false; Text = ''; Backend = $backend
                Error   = "Unknown backend: $backend (use 'api' or 'claude-code')"
            }
        }
    }
}
