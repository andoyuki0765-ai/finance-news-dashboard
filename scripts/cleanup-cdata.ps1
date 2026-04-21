#Requires -Version 5.1
<#
.SYNOPSIS
  既存データの #cdata-section / System.Xml.XmlElement 汚染をクリーンアップする
.DESCRIPTION
  - title から '#cdata-section -+\s+' プレフィックスを除去
  - description が 'System.Xml.XmlElement' のみなら空文字に
  - data/raw/, data/topics/ 両方を対象
  - バックアップ: 各JSONを *.json.bak としてコピー
#>
[CmdletBinding()]
param([string]$Root = '')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }

$RawDir    = Join-Path $Root 'data\raw'
$TopicsDir = Join-Path $Root 'data\topics'

function Clean-Article {
    param($a)
    $changed = $false
    if ($a.title) {
        # '#cdata-section --------------\s' プレフィックス除去（ハイフンの数は可変）
        $newTitle = $a.title -replace '^\s*#cdata-section\s*-+\s*', ''
        if ($newTitle -ne $a.title) {
            $a.title = $newTitle
            $changed = $true
        }
    }
    if ($a.description) {
        # 'System.Xml.XmlElement' のみなら空文字
        if ($a.description -eq 'System.Xml.XmlElement') {
            $a.description = ''
            $changed = $true
        }
    }
    return $changed
}

$totalFixed = 0
$filesProcessed = 0

foreach ($dir in @($TopicsDir, $RawDir)) {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem $dir -Filter '*.json' | ForEach-Object {
        $file = $_.FullName
        $data = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $data.articles) { return }

        $fixedInFile = 0
        foreach ($a in $data.articles) {
            if (Clean-Article $a) { $fixedInFile++ }
        }

        if ($fixedInFile -gt 0) {
            # バックアップ
            $backupFile = "$file.bak"
            if (-not (Test-Path $backupFile)) {
                Copy-Item $file $backupFile
            }
            # 保存
            $data | ConvertTo-Json -Depth 6 | Out-File -FilePath $file -Encoding UTF8
            Write-Host ("  {0}: {1}件修正" -f $_.Name, $fixedInFile)
            $totalFixed += $fixedInFile
            $filesProcessed++
        }
    }
}

Write-Host ""
Write-Host ("✅ クリーンアップ完了: {0}ファイル / 計{1}件修正" -f $filesProcessed, $totalFixed)
Write-Host "   バックアップ: 元のJSONは *.json.bak として保存されています"
Write-Host "   ロールバック: Get-ChildItem -Recurse -Filter '*.json.bak' | ForEach { Move-Item $_.FullName $_.FullName.Replace('.bak','') -Force }"
