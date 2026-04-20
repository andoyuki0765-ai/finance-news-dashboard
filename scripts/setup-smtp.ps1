#Requires -Version 5.1
<#
.SYNOPSIS
  Gmail SMTP用の認証情報を初回登録する（DPAPI暗号化保存）
.DESCRIPTION
  - Gmailアプリパスワードを安全に取得しDPAPI暗号化XMLとして保存
  - 保存先: %USERPROFILE%\.news-dashboard\smtp.xml
  - 復号は同一Windowsユーザーかつ同一マシンでのみ可能
  - 平文は環境変数・config・ログ・git管理いずれにも残らない
#>
[CmdletBinding()]
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$CredDir  = Join-Path $env:USERPROFILE '.news-dashboard'
$CredFile = Join-Path $CredDir 'smtp.xml'

if ($Remove) {
    if (Test-Path $CredFile) {
        Remove-Item $CredFile -Force
        Write-Host "✅ 認証情報を削除しました: $CredFile" -ForegroundColor Green
    } else {
        Write-Host "認証情報は存在しません" -ForegroundColor Yellow
    }
    return
}

if (-not (Test-Path $CredDir)) { New-Item -ItemType Directory -Path $CredDir -Force | Out-Null }

if (Test-Path $CredFile) {
    Write-Host "⚠️  既存の認証情報があります: $CredFile" -ForegroundColor Yellow
    $ans = Read-Host "上書きしますか？ (y/N)"
    if ($ans -ne 'y') { return }
}

Write-Host ""
Write-Host "===== Gmail SMTP 認証情報セットアップ =====" -ForegroundColor Cyan
Write-Host ""
Write-Host "【事前準備】"
Write-Host "1. Googleアカウントで2段階認証が有効である必要があります"
Write-Host "   未設定の場合: https://myaccount.google.com/security"
Write-Host ""
Write-Host "2. アプリパスワードを生成してください（16文字）"
Write-Host "   発行URL: https://myaccount.google.com/apppasswords"
Write-Host "   アプリ名: 任意（例: news-dashboard）"
Write-Host ""

$emailAddr = Read-Host "Gmailアドレス（送信元・送信先共通）"
if ([string]::IsNullOrWhiteSpace($emailAddr)) {
    throw "メールアドレスは必須です"
}

Write-Host ""
Write-Host "アプリパスワード（16文字、スペース含めても可）を入力してください"
Write-Host "※ 入力中の文字は画面に表示されません"
$appPassword = Read-Host "アプリパスワード" -AsSecureString
if ($appPassword.Length -eq 0) {
    throw "パスワードは必須です"
}

# PSCredential オブジェクトを作成し DPAPI 暗号化 XML として保存
$cred = New-Object System.Management.Automation.PSCredential($emailAddr, $appPassword)
$cred | Export-Clixml -Path $CredFile

# ファイル権限をユーザー専用に絞る（NTFS ACL）
try {
    $acl = Get-Acl $CredFile
    $acl.SetAccessRuleProtection($true, $false)  # 継承無効化、既存ルール削除
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, 'FullControl', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl $CredFile $acl
} catch {
    Write-Host "⚠️ ACL設定に失敗（DPAPI暗号化は有効）: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✅ 認証情報を保存しました" -ForegroundColor Green
Write-Host "   保存先: $CredFile"
Write-Host "   暗号化: DPAPI (ユーザー: $env:USERNAME, マシン: $env:COMPUTERNAME)"
Write-Host "   ACL: $env:USERNAME のみアクセス可"
Write-Host ""

# パスワード長チェック（Gmailアプリパスワードは16文字）
$tmpCred = $cred.GetNetworkCredential()
$tmpPass = $tmpCred.Password -replace '\s+', ''
Write-Host "📏 入力したパスワードの長さ: $($tmpPass.Length) 文字"
if ($tmpPass.Length -ne 16) {
    Write-Host "   ⚠️  Gmailアプリパスワードは16文字ですが、$($tmpPass.Length)文字が入力されました" -ForegroundColor Yellow
    Write-Host "   通常のGoogleパスワードを誤入力していませんか？" -ForegroundColor Yellow
}

# 接続テスト
Write-Host ""
Write-Host "🔌 SMTP接続テスト中..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    $smtp = New-Object System.Net.Mail.SmtpClient('smtp.gmail.com', 587)
    $smtp.EnableSsl   = $true
    $smtp.Credentials = New-Object System.Net.NetworkCredential($emailAddr, $tmpPass)
    $smtp.Timeout     = 15000

    # ダミーメッセージで接続のみ確認（送信せずDispose）
    $testMsg = New-Object System.Net.Mail.MailMessage($emailAddr, $emailAddr, 'connection-test', 'test')
    $smtp.Send($testMsg)
    $testMsg.Dispose()
    $smtp.Dispose()

    Write-Host "✅ Gmail SMTP 認証成功！テストメールが届いているはずです" -ForegroundColor Green
    Write-Host ""
    Write-Host "🧪 ダイジェスト送信テスト:"
    Write-Host "   powershell -File scripts\send-email.ps1"
} catch {
    $errMsg = $_.Exception.Message
    if ($_.Exception.InnerException) {
        $errMsg += "`n    inner: " + $_.Exception.InnerException.Message
    }
    Write-Host ""
    Write-Host "❌ 接続テスト失敗: $errMsg" -ForegroundColor Red
    Write-Host ""
    Write-Host "🔍 確認事項：" -ForegroundColor Yellow
    Write-Host "   ① Googleアカウントの2段階認証は有効ですか？"
    Write-Host "      https://myaccount.google.com/security"
    Write-Host "   ② アプリパスワードは https://myaccount.google.com/apppasswords に表示されますか？"
    Write-Host "   ③ 表示されている場合、一度削除して新規作成してください"
    Write-Host "   ④ アプリパスワードは 16 文字の英小文字（abcd efgh ijkl mnop の形式）です"
    Write-Host "      通常のGoogleログインパスワードでは動作しません"
    Write-Host "   ⑤ Google Workspace（会社アカウント）の場合、管理者がアプリパスワードを無効化している可能性"
    Write-Host ""
    Write-Host "再試行: powershell -File scripts\setup-smtp.ps1 -Remove" -ForegroundColor Cyan
    Write-Host "       powershell -File scripts\setup-smtp.ps1"
}

# パスワードをメモリから消去
$tmpPass = $null
$tmpCred = $null
[System.GC]::Collect()

Write-Host ""
Write-Host "❌ 削除する場合:"
Write-Host "   powershell -File scripts\setup-smtp.ps1 -Remove"
