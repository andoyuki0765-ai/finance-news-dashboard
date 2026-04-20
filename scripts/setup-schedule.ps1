#Requires -Version 5.1
<#
.SYNOPSIS
  Windowsタスクスケジューラに1日4回（00:00/06:00/12:00/18:00）実行のタスクを登録する
.DESCRIPTION
  既存タスクがあれば上書きします。管理者権限は不要です（ユーザータスクとして登録）。
.EXAMPLE
  # デフォルト4回配信で登録
  .\setup-schedule.ps1
.EXAMPLE
  # 任意の時刻配列で登録
  .\setup-schedule.ps1 -TriggerTimes @('07:00','19:00')
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'NewsDashboardDaily',
    [string[]]$TriggerTimes = @('00:00','06:00','12:00','18:00'),
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root      = Split-Path -Parent $PSScriptRoot
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

# 複数のトリガーを配列で生成
$triggers = @()
foreach ($t in $TriggerTimes) {
    $triggers += New-ScheduledTaskTrigger -Daily -At $t
}

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew  # 既に走っていれば新規起動を抑止

$timeList = $TriggerTimes -join ', '

# 管理者権限不要のユーザータスクとして登録（ログオン中のみ実行）
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $triggers `
    -Settings $settings `
    -Description "毎日 $timeList に金融ニュースを取得し、単元別ダッシュボード更新＋メール配信" | Out-Null

Write-Host ""
Write-Host "✅ タスクを登録しました"
Write-Host "   タスク名: $TaskName"
Write-Host "   実行時刻: 毎日 $timeList （計 $($TriggerTimes.Count) 回）"
Write-Host "   実行内容: $RunScript"
Write-Host "   設定    : 既に実行中なら次のトリガーをスキップ（重複実行防止）"
Write-Host ""
Write-Host "📋 確認コマンド:"
Write-Host "   Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host ""
Write-Host "🔧 手動実行（即時テスト）:"
Write-Host "   Start-ScheduledTask -TaskName '$TaskName'"
Write-Host ""
Write-Host "❌ 削除する場合:"
Write-Host "   .\setup-schedule.ps1 -Unregister"
