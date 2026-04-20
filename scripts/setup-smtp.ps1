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
Write-Host "🧪 テスト送信:"
Write-Host "   powershell -File scripts\send-email.ps1 -TestOnly"
Write-Host ""
Write-Host "❌ 削除する場合:"
Write-Host "   powershell -File scripts\setup-smtp.ps1 -Remove"
