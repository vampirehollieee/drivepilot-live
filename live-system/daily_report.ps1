param(
    [string]$Date = (Get-Date -Format "yyyy-MM-dd")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$dataDir = Join-Path $projectRoot "live-data"
$reportsDir = Join-Path $projectRoot "reports"
$notificationsPath = Join-Path $dataDir "notifications.jsonl"

function Get-Value {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
    }
    return $null
}

function Get-EntryTime {
    param($Object)
    $raw = Get-Value -Object $Object -Names @("timestamp", "time", "created_at", "received_at")
    if ($null -eq $raw) { return $null }
    try { return [datetime]::Parse([string]$raw) } catch { return $null }
}

function Get-EntryText {
    param($Object, [int]$MaxLength = 90)
    $text = Get-Value -Object $Object -Names @("text", "message", "raw_text", "body")
    if ($null -eq $text -and $Object.PSObject.Properties.Name -contains "raw") {
        $text = Get-Value -Object $Object.raw -Names @("text", "message", "body")
    }
    $text = (([string]$text -replace "[\r\n]+", " ") -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return "--" }
    if ($text.Length -gt $MaxLength) { return $text.Substring(0, $MaxLength) + "..." }
    return $text
}

function Get-Tags {
    param($Object)
    $tags = @()
    if ($Object.PSObject.Properties.Name -contains "tags" -and $null -ne $Object.tags) {
        foreach ($tag in @($Object.tags)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$tag)) { $tags += [string]$tag }
        }
    }
    return $tags
}

function Test-DispatcherPrivate {
    param($Object)
    if ($Object.PSObject.Properties.Name -contains "dispatcher_private" -and [bool]$Object.dispatcher_private) {
        return $true
    }
    return ((Get-Tags $Object) -contains "dispatcher_private")
}

function Test-HotZone {
    param($Object)
    $kind = [string](Get-Value -Object $Object -Names @("kind", "type"))
    if ($kind -match "hotzone|hot_zone|hot|zone") { return $true }
    foreach ($tag in (Get-Tags $Object)) {
        if ($tag -match "hotzone|hot_zone|hot|zone") { return $true }
    }
    return $false
}

function Get-Confidence {
    param($Object)
    $confidence = [string](Get-Value -Object $Object -Names @("confidence"))
    if (-not [string]::IsNullOrWhiteSpace($confidence)) { return $confidence.ToLowerInvariant() }
    $score = Get-Value -Object $Object -Names @("confidence_score")
    if ($null -ne $score) {
        try {
            $number = [double]$score
            if ($number -ge 0.8) { return "high" }
            if ($number -ge 0.5) { return "medium" }
            return "low"
        }
        catch {}
    }
    if ($Object.PSObject.Properties.Name -contains "places" -and $null -ne $Object.places) {
        $placeConfidences = @()
        foreach ($place in @($Object.places)) {
            $placeConfidence = [string](Get-Value -Object $place -Names @("confidence"))
            if (-not [string]::IsNullOrWhiteSpace($placeConfidence)) {
                $placeConfidences += $placeConfidence.ToLowerInvariant()
            }
        }
        if ($placeConfidences -contains "high") { return "high" }
        if ($placeConfidences -contains "medium") { return "medium" }
        if ($placeConfidences -contains "low") { return "low" }
    }
    return ""
}

function Get-Locations {
    param($Object)
    $names = @()
    foreach ($field in @("area", "place", "landmark", "address")) {
        $value = Get-Value -Object $Object -Names @($field)
        if ($null -ne $value) { $names += [string]$value }
    }
    if ($Object.PSObject.Properties.Name -contains "addresses" -and $null -ne $Object.addresses) {
        foreach ($address in @($Object.addresses)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$address)) { $names += [string]$address }
        }
    }
    if ($Object.PSObject.Properties.Name -contains "places" -and $null -ne $Object.places) {
        foreach ($place in @($Object.places)) {
            $alias = Get-Value -Object $place -Names @("alias", "landmark", "place")
            $address = Get-Value -Object $place -Names @("address")
            if ($null -ne $alias) { $names += [string]$alias }
            elseif ($null -ne $address) { $names += [string]$address }
        }
    }
    return @($names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-PrimaryLocation {
    param($Object)
    $locations = @(Get-Locations $Object)
    if ($locations.Count -gt 0) { return $locations[0] }
    return Get-EntryText -Object $Object -MaxLength 70
}

function Add-Count {
    param([hashtable]$Table, [string]$Key, [int]$Amount = 1)
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    if (-not $Table.ContainsKey($Key)) { $Table[$Key] = 0 }
    $Table[$Key] += $Amount
}

function Get-TopRows {
    param([hashtable]$Table, [int]$Top = 10)
    return @(
        $Table.GetEnumerator() |
            Sort-Object @{ Expression = "Value"; Descending = $true }, @{ Expression = "Key"; Descending = $false } |
            Select-Object -First $Top
    )
}

try {
    $targetDate = [datetime]::Parse($Date).Date
}
catch {
    Write-Error "Invalid date. Use YYYY-MM-DD, for example -Date `"2026-04-27`"."
    exit 1
}

if (-not (Test-Path -LiteralPath $notificationsPath)) {
    Write-Error "Missing notifications file: $notificationsPath"
    exit 1
}

New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null

$items = New-Object System.Collections.Generic.List[object]
$skippedInvalidLines = 0

foreach ($line in Get-Content -Path $notificationsPath -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
        $entry = $line | ConvertFrom-Json
        $dt = Get-EntryTime $entry
        if ($null -eq $dt) { continue }
        if ($dt.Date -ne $targetDate) { continue }
        $items.Add([pscustomobject]@{ Entry = $entry; DateTime = $dt }) | Out-Null
    }
    catch {
        $skippedInvalidLines++
    }
}

$notifications = @($items.ToArray())
$locatableItems = @($notifications | Where-Object { (Get-Confidence $_.Entry) -eq "high" })
$mediumItems = @($notifications | Where-Object { (Get-Confidence $_.Entry) -eq "medium" })
$hotZoneItems = @($notifications | Where-Object { Test-HotZone $_.Entry })
$dispatcherItems = @($notifications | Where-Object { Test-DispatcherPrivate $_.Entry })
$locationItems = @($notifications | Where-Object { @(Get-Locations $_.Entry).Count -gt 0 })

$hourCounts = @{}
for ($hour = 0; $hour -lt 24; $hour++) {
    $label = "{0:00}:00-{1:00}:00" -f $hour, (($hour + 1) % 24)
    $hourCounts[$label] = 0
}
foreach ($item in $notifications) {
    $label = "{0:00}:00-{1:00}:00" -f $item.DateTime.Hour, (($item.DateTime.Hour + 1) % 24)
    Add-Count -Table $hourCounts -Key $label
}

$topHours = @(Get-TopRows -Table $hourCounts -Top 24 | Where-Object { $_.Value -gt 0 } | Select-Object -First 3)

$locationCounts = @{}
foreach ($item in $notifications) {
    foreach ($location in @(Get-Locations $item.Entry)) {
        Add-Count -Table $locationCounts -Key $location
    }
}

$dispatcherKeywordCounts = @{}
foreach ($item in $dispatcherItems) {
    $keyword = [string](Get-Value -Object $item.Entry -Names @("dispatcher_keyword"))
    if ([string]::IsNullOrWhiteSpace($keyword)) { $keyword = "unmarked" }
    Add-Count -Table $dispatcherKeywordCounts -Key $keyword
}

$hotZoneCounts = @{}
foreach ($item in $hotZoneItems) {
    Add-Count -Table $hotZoneCounts -Key (Get-PrimaryLocation $item.Entry)
}

$dateText = $targetDate.ToString("yyyy-MM-dd")
$md = New-Object System.Collections.Generic.List[string]

$md.Add("# DrivePilot Daily Report - $dateText")
$md.Add("")
$volumeLabel = "low"
if ($notifications.Count -ge 200) { $volumeLabel = "high" }
elseif ($notifications.Count -ge 50) { $volumeLabel = "normal" }
$topHourText = if ($topHours.Count -gt 0) { ($topHours | ForEach-Object { $_.Key }) -join ", " } else { "--" }
$topLocationItems = @(Get-TopRows -Table $locationCounts -Top 3)
$topLocationText = if ($topLocationItems.Count -gt 0) { ($topLocationItems | ForEach-Object { $_.Key }) -join ", " } else { "--" }
$dispatcherLabel = if ($dispatcherItems.Count -ge 5) { "high" } elseif ($dispatcherItems.Count -gt 0) { "normal" } else { "low" }

$md.Add("## Today Review")
$md.Add("")
$md.Add("- Signal volume: $volumeLabel")
$md.Add("- Most active hours: $topHourText")
$md.Add("- Most common places: $topLocationText")
$md.Add("- Personal reminders: $dispatcherLabel")
$md.Add("- Note: this report is for after-work review only. It does not make forced driving decisions.")
$md.Add("")

$md.Add("## Daily Overview")
$md.Add("")
$md.Add("| Metric | Count |")
$md.Add("|---|---:|")
$md.Add("| Total notifications | $($notifications.Count) |")
$md.Add("| Locatable signal count | $($locatableItems.Count) |")
$md.Add("| Partial location signal count | $($mediumItems.Count) |")
$md.Add("| Hot zone events | $($hotZoneItems.Count) |")
$md.Add("| Personal reminders | $($dispatcherItems.Count) |")
$md.Add("| With address/landmark | $($locationItems.Count) |")
$md.Add("")

$md.Add("## Hourly Analysis")
$md.Add("")
$md.Add("### Top 3 Active Hours")
$md.Add("")
$md.Add("| Rank | Hour | Notifications |")
$md.Add("|---:|---|---:|")
if ($topHours.Count -gt 0) {
    $rank = 1
    foreach ($row in $topHours) {
        $md.Add("| $rank | $($row.Key) | $($row.Value) |")
        $rank++
    }
}
else {
    $md.Add("| -- | -- | 0 |")
}
$md.Add("")
$md.Add("### Hourly Notification Count")
$md.Add("")
$md.Add("| Hour | Notifications |")
$md.Add("|---|---:|")
foreach ($hour in 0..23) {
    $label = "{0:00}:00-{1:00}:00" -f $hour, (($hour + 1) % 24)
    $md.Add("| $label | $($hourCounts[$label]) |")
}
$md.Add("")

$md.Add("## Place / Area Ranking")
$md.Add("")
$locationRows = @(Get-TopRows -Table $locationCounts -Top 10)
if ($locationRows.Count -eq 0) {
    $md.Add("Not enough place data today.")
}
else {
    $md.Add("| Rank | Place | Count |")
    $md.Add("|---:|---|---:|")
    $rank = 1
    foreach ($row in $locationRows) {
        $md.Add("| $rank | $($row.Key) | $($row.Value) |")
        $rank++
    }
}
$md.Add("")

$md.Add("## Personal Reminder Summary")
$md.Add("")
$md.Add("| Metric | Count |")
$md.Add("|---|---:|")
$md.Add("| Personal reminder total | $($dispatcherItems.Count) |")
$keywordRows = @(Get-TopRows -Table $dispatcherKeywordCounts -Top 10)
$md.Add("")
$md.Add("### Keyword Ranking")
$md.Add("")
if ($keywordRows.Count -gt 0) {
    $md.Add("| Keyword | Count |")
    $md.Add("|---|---:|")
    foreach ($row in $keywordRows) { $md.Add("| $($row.Key) | $($row.Value) |") }
} else {
    $md.Add("None")
}
$md.Add("")
$md.Add("### Recent 5 Personal Reminders")
$md.Add("")
$md.Add("| Time | Keyword | Summary |")
$md.Add("|---|---|---|")
$recentDispatcher = @($dispatcherItems | Sort-Object DateTime -Descending | Select-Object -First 5)
if ($recentDispatcher.Count -eq 0) {
    $md.Add("| -- | -- | None |")
}
else {
    foreach ($item in $recentDispatcher) {
        $keyword = [string](Get-Value -Object $item.Entry -Names @("dispatcher_keyword"))
        if ([string]::IsNullOrWhiteSpace($keyword)) { $keyword = "unmarked" }
        $md.Add("| $($item.DateTime.ToString('HH:mm')) | $keyword | $(Get-EntryText -Object $item.Entry -MaxLength 70) |")
    }
}
$md.Add("")

$md.Add("## Locatable Signal Summary")
$md.Add("")
$md.Add("Recent 10:")
$md.Add("")
$recentHigh = @($locatableItems | Sort-Object DateTime -Descending | Select-Object -First 10)
if ($recentHigh.Count -eq 0) {
    $md.Add("No locatable signal today.")
}
else {
    $md.Add("| Time | Place/Address | Location status |")
    $md.Add("|---|---|---|")
    foreach ($item in $recentHigh) {
        $md.Add("| $($item.DateTime.ToString('HH:mm')) | $(Get-PrimaryLocation $item.Entry) | locatable |")
    }
}
$md.Add("")

$md.Add("## Hot Zone Summary")
$md.Add("")
$md.Add("| Metric | Count |")
$md.Add("|---|---:|")
$md.Add("| Hot zone event total | $($hotZoneItems.Count) |")
$hotZoneRows = @(Get-TopRows -Table $hotZoneCounts -Top 5)
if ($hotZoneRows.Count -gt 0) {
    $md.Add("")
    $md.Add("| Place | Count |")
    $md.Add("|---|---:|")
    foreach ($row in $hotZoneRows) { $md.Add("| $($row.Key) | $($row.Value) |") }
}
$md.Add("")
$md.Add("### Recent 5 Hot Zone Signals")
$md.Add("")
$md.Add("| Time | Place/Summary |")
$md.Add("|---|---|")
$recentHotZones = @($hotZoneItems | Sort-Object DateTime -Descending | Select-Object -First 5)
if ($recentHotZones.Count -eq 0) {
    $md.Add("| -- | None |")
}
else {
    foreach ($item in $recentHotZones) {
        $md.Add("| $($item.DateTime.ToString('HH:mm')) | $(Get-PrimaryLocation $item.Entry) |")
    }
}
$md.Add("")

$md.Add("## System Notes")
$md.Add("")
$md.Add("- skipped_invalid_lines: $skippedInvalidLines")
$md.Add("- Data source: live-data/notifications.jsonl")
$md.Add("- Generated at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$reportPath = Join-Path $reportsDir ("daily_{0}.md" -f $dateText)
$md | Set-Content -Path $reportPath -Encoding UTF8

Write-Host "[DrivePilot Daily] date=$dateText"
Write-Host "[DrivePilot Daily] notifications=$($notifications.Count) locatable=$($locatableItems.Count) medium=$($mediumItems.Count) hotzone=$($hotZoneItems.Count) dispatcher_private=$($dispatcherItems.Count)"
Write-Host "[DrivePilot Daily] skipped_invalid_lines=$skippedInvalidLines"
Write-Host "[DrivePilot Daily] report=reports/daily_$dateText.md"
