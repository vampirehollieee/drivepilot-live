param(
    [string]$DataDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DataDir)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $DataDir = Join-Path (Split-Path -Parent $scriptDir) "live-data"
}

$placesPath = Join-Path $DataDir "places.csv"
$hotZonesPath = Join-Path $DataDir "hot_zones.json"

function Get-Area {
    param([AllowNull()][string]$Address)
    if ($Address -match "Demo City([\p{IsCJKUnifiedIdeographs}]{1,4}區)") {
        return $matches[1]
    }
    if ($Address -match "^([\p{IsCJKUnifiedIdeographs}]{1,4}區)") {
        return $matches[1]
    }
    return "未知"
}

function Read-PlaceRows {
    if (-not (Test-Path -LiteralPath $placesPath)) { return @() }
    try {
        return @(Import-Csv -Path $placesPath -Encoding UTF8)
    }
    catch {
        return @()
    }
}

$now = Get-Date
$rows = Read-PlaceRows | Where-Object {
    $seen = [datetime]::MinValue
    [datetime]::TryParse([string]$_.timestamp, [ref]$seen)
} | ForEach-Object {
    $seen = [datetime]::Parse([string]$_.timestamp)
    [pscustomobject]@{
        timestamp = $seen
        group = [string]$_.group
        address = [string]$_.address
        confidence = if ([string]::IsNullOrWhiteSpace([string]$_.confidence)) { "low" } else { [string]$_.confidence }
        area = Get-Area ([string]$_.address)
    }
}

$recent15 = @($rows | Where-Object { ($now - $_.timestamp).TotalMinutes -le 15 })
$recent60 = @($rows | Where-Object { ($now - $_.timestamp).TotalMinutes -le 60 })
$valid15Count = $recent15.Count
$valid60Count = $recent60.Count

$marketHeat = if ($valid15Count -le 1) {
    "冷"
}
elseif ($valid15Count -le 4) {
    "普通"
}
else {
    "熱"
}

$baseAdvice = switch ($marketHeat) {
    "冷" { "不建議特地出車" }
    "普通" { "可短跑觀察" }
    "熱" { "可上線觀察" }
}

$zones = @()
foreach ($group in ($rows | Group-Object area)) {
    $items = @($group.Group)
    $items15 = @($items | Where-Object { ($now - $_.timestamp).TotalMinutes -le 15 })
    $items30 = @($items | Where-Object { ($now - $_.timestamp).TotalMinutes -le 30 })
    $items60 = @($items | Where-Object { ($now - $_.timestamp).TotalMinutes -le 60 })
    if ($items60.Count -eq 0) { continue }

    $highCount = @($items60 | Where-Object { $_.confidence -eq "high" }).Count
    $mediumCount = @($items60 | Where-Object { $_.confidence -eq "medium" }).Count
    $lowCount = @($items60 | Where-Object { $_.confidence -eq "low" }).Count
    $latest = $items | Sort-Object timestamp -Descending | Select-Object -First 1
    $topGroups = @($items60 | Group-Object group | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object {
        [pscustomobject]@{
            group = $_.Name
            count = $_.Count
        }
    })

    $score = ($items15.Count * 4) + ($items30.Count * 2) + $items60.Count + ($highCount * 2) + $mediumCount
    $zones += [pscustomobject]@{
        area = $group.Name
        score = $score
        count_15min = $items15.Count
        count_30min = $items30.Count
        count_60min = $items60.Count
        high_confidence_count = $highCount
        medium_confidence_count = $mediumCount
        low_confidence_count = $lowCount
        latest_address = $latest.address
        latest_seen_time = $latest.timestamp.ToString("yyyy-MM-dd HH:mm:ss")
        top_groups = $topGroups
    }
}

$zones = @($zones | Sort-Object score, latest_seen_time -Descending)
$topZones = @($zones | Select-Object -First 3)
$latestHigh = $rows | Where-Object { $_.confidence -eq "high" -and ($now - $_.timestamp).TotalMinutes -le 60 } | Sort-Object timestamp -Descending | Select-Object -First 1

$advice = $baseAdvice
if ($topZones.Count -gt 0 -and @($topZones | Where-Object { $_.high_confidence_count -gt 0 }).Count -gt 0) {
    $advice = "$baseAdvice；可優先觀察$($topZones[0].area)"
}

$output = [pscustomobject]@{
    generated_at = $now.ToString("yyyy-MM-dd HH:mm:ss")
    market_heat = $marketHeat
    advice = $advice
    recent_15min_valid_count = $valid15Count
    recent_60min_valid_count = $valid60Count
    latest_high_confidence_address = if ($latestHigh) { $latestHigh.address } else { "" }
    latest_high_confidence_area = if ($latestHigh) { $latestHigh.area } else { "" }
    zones = $zones
}

$output | ConvertTo-Json -Depth 8 | Set-Content -Path $hotZonesPath -Encoding UTF8
Write-Host "updated $hotZonesPath"

