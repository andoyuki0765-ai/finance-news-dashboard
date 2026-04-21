#Requires -Version 5.1
<#
.SYNOPSIS
  RSSフィードを取得し、24時間以内の新着記事をJSONに保存する
#>
[CmdletBinding()]
param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }

$ConfigPath = Join-Path $Root 'config\sources.json'
$RawDir     = Join-Path $Root 'data\raw'
$LogDir     = Join-Path $Root 'logs'

if (-not (Test-Path $RawDir)) { New-Item -ItemType Directory -Path $RawDir -Force | Out-Null }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$Today    = Get-Date -Format 'yyyy-MM-dd'
$Cutoff   = (Get-Date).AddHours(-24)
$LogFile  = Join-Path $LogDir "fetch-$Today.log"
$OutFile  = Join-Path $RawDir "$Today.json"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$stamp [$Level] $Message" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

function ConvertTo-DateTime {
    param([string]$RawDate)
    if ([string]::IsNullOrWhiteSpace($RawDate)) { return $null }
    try { return [DateTime]::Parse($RawDate) } catch {}
    try { return [DateTime]::ParseExact($RawDate, 'ddd, dd MMM yyyy HH:mm:ss zzz', [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
    try { return [DateTime]::ParseExact($RawDate, 'yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
    return $null
}

function Get-CleanText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $clean = $Text -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
    return ($clean -replace '\s+', ' ').Trim()
}

# XmlElement / CDATA / 文字列のいずれでも正しくテキストを取り出す
function Get-XmlNodeText {
    param($node)
    if ($null -eq $node) { return '' }
    if ($node -is [string]) { return $node }
    # XmlElement の場合、InnerText で CDATA含む子ノードのテキストを再帰的に取得
    if ($node.PSObject.Properties.Name -contains 'InnerText') {
        return [string]$node.InnerText
    }
    # 配列で複数要素ある場合は最初を採用
    if ($node -is [System.Array] -and $node.Length -gt 0) {
        return Get-XmlNodeText $node[0]
    }
    return [string]$node
}

Write-Log "Fetch start. Output: $OutFile"

if (-not (Test-Path $ConfigPath)) {
    Write-Log "Config not found: $ConfigPath" 'ERROR'
    exit 1
}

$config   = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$articles = New-Object System.Collections.Generic.List[object]
$seen     = New-Object System.Collections.Generic.HashSet[string]

foreach ($feed in $config.feeds) {
    Write-Log "Fetching: $($feed.name) <$($feed.url)>"
    try {
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) NewsDashboard/1.0' }
        $response = Invoke-WebRequest -Uri $feed.url -Headers $headers -TimeoutSec 30 -UseBasicParsing
        [xml]$xml = [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())

        # RSS 2.0 (rss/channel/item) と RDF (rdf:RDF/item) と Atom (feed/entry) の3形式に対応
        $items = @()
        if ($xml.rss -and $xml.rss.channel -and $xml.rss.channel.item) {
            $items = $xml.rss.channel.item
        } elseif ($xml.RDF -and $xml.RDF.item) {
            $items = $xml.RDF.item
        } elseif ($xml.feed -and $xml.feed.entry) {
            $items = $xml.feed.entry
        }

        $count = 0
        foreach ($item in $items) {
            # CDATA・XmlElement・通常文字列のすべてに対応する Get-XmlNodeText を使用
            $title = Get-XmlNodeText $item.title

            # link は Atom feed では href 属性を持つ
            $link = if ($item.link -is [string]) { $item.link }
                    elseif ($item.link.href) { [string]$item.link.href }
                    else { Get-XmlNodeText $item.link }

            $desc = if ($item.description) { Get-XmlNodeText $item.description }
                    elseif ($item.summary) { Get-XmlNodeText $item.summary }
                    elseif ($item.'content:encoded') { Get-XmlNodeText $item.'content:encoded' }
                    else { '' }

            $rawDt = if ($item.pubDate) { Get-XmlNodeText $item.pubDate }
                     elseif ($item.'dc:date') { Get-XmlNodeText $item.'dc:date' }
                     elseif ($item.published) { Get-XmlNodeText $item.published }
                     elseif ($item.updated) { Get-XmlNodeText $item.updated }
                     else { $null }

            $title = Get-CleanText $title
            $desc  = Get-CleanText $desc
            $link  = if ($link) { ([string]$link).Trim() } else { '' }
            $dt    = ConvertTo-DateTime $rawDt

            if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($link)) { continue }
            if ($dt -and $dt -lt $Cutoff) { continue }

            # 重複排除（URLベース）
            if (-not $seen.Add($link)) { continue }

            $articles.Add([pscustomobject]@{
                source      = $feed.name
                title       = $title
                url         = $link
                description = $desc
                publishedAt = if ($dt) { $dt.ToString('yyyy-MM-ddTHH:mm:ssK') } else { '' }
                fetchedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
            })
            $count++
        }
        Write-Log ("  -> {0}件取得" -f $count)
    } catch {
        Write-Log "  失敗: $($_.Exception.Message)" 'WARN'
    }
}

$result = [pscustomobject]@{
    generatedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    cutoffAt      = $Cutoff.ToString('yyyy-MM-ddTHH:mm:ssK')
    articleCount  = $articles.Count
    articles      = $articles
}

$result | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutFile -Encoding UTF8
Write-Log "Done. Total: $($articles.Count) articles -> $OutFile"
