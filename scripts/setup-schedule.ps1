#Requires -Version 5.1
<#
.SYNOPSIS
  Windowsタスクスケジューラに毎朝6:00実行のタスクを登録する
.DESCRIPTION
  既存タスクがあれば上書きします。管理者権限は不要です（ユーザータスクとして登録）。
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'NewsDashboardDaily',
    [string]$TriggerTime = '06:00',
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root      = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$RunScript = Join-Path $Root 'scripts\run-daily.ps1'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "✅ タスク '$TaskName' を削除しました"
    } else {
        Write-Host "ℹ️ タスク '$TaskName' は登録されていません"
    }
    return
}

if (-not (Test-Path $RunScript)) {
    throw "Run script not found: $RunScript"
}

# 既存タスクがあれば削除
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "⚠️ 既存のタスク '$TaskName' を上書きします"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RunScript`"" `
    -WorkingDirectory $Root

$trigger = New-ScheduledTaskTrigger -Daily -At $TriggerTime

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

# 管理者権限不要のユーザータスクとして登録（ログオン中のみ実行）
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description '毎朝6:00に金融ニュースを取得し、単元別ダッシュボードを更新します' | Out-Null

Write-Host ""
Write-Host "✅ タスクを登録しました"
Write-Host "   タスク名: $TaskName"
Write-Host "   実行時刻: 毎日 $TriggerTime"
Write-Host "   実行内容: $RunScript"
Write-Host ""
Write-Host "📋 確認コマンド:"
Write-Host "   Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host ""
Write-Host "🔧 手動実行:"
Write-Host "   Start-ScheduledTask -TaskName '$TaskName'"
Write-Host ""
Write-Host "❌ 削除する場合:"
Write-Host "   .\setup-schedule.ps1 -Unregister"
