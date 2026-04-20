#Requires -Version 5.1
<#
.SYNOPSIS
  LLMバックエンドのスモークテスト（最小コスト）
#>
[CmdletBinding()]
param(
    [ValidateSet('api','claude-code','auto')]
    [string]$Backend = 'auto'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'llm-helper.ps1')

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$cfg  = Get-Content (Join-Path $Root 'config\api.json') -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Backend -ne 'auto') {
    $cfg.backend = $Backend
    if ($Backend -eq 'claude-code') {
        # 軽量モデルでテスト
        $cfg.claude_code.model = 'haiku'
    }
}

Write-Host "===== LLM Smoke Test ====="
Write-Host "Backend: $($cfg.backend)"
if ($cfg.backend -eq 'claude-code') {
    Write-Host "Model: $($cfg.claude_code.model)"
} else {
    Write-Host "Model: $($cfg.model)"
}
Write-Host ""

$systemPrompt = 'あなたは日本語のテストアシスタントです。指示通りのJSONのみを返してください（前後の説明文不要）。'
$userMessage  = '{"status":"ok","msg":"hello"} というJSONを返してください。'

$start = Get-Date
$result = Invoke-LLM -Config $cfg -SystemPrompt $systemPrompt -UserMessage $userMessage -MaxTokens 256
$elapsed = ((Get-Date) - $start).TotalSeconds

Write-Host "===== Result ====="
Write-Host ("Success: {0}" -f $result.Success)
Write-Host ("Backend: {0}" -f $result.Backend)
Write-Host ("Elapsed: {0:N1} sec" -f $elapsed)
if ($result.Error) {
    Write-Host "Error: $($result.Error)" -ForegroundColor Red
}
Write-Host ""
Write-Host "----- Response Text -----"
Write-Host $result.Text
Write-Host "-------------------------"
if ($result.Usage) {
    Write-Host ""
    Write-Host "Usage:"
    $result.Usage | Format-List
}
