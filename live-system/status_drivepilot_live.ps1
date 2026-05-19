param(
    [int]$MapPort = 8790,
    [int]$ReceiverPort = 8788
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$dataDir = Join-Path $projectRoot "live-data"
$notificationsPath = Join-Path $dataDir "notifications.jsonl"
$placesPath = Join-Path $dataDir "places.csv"
$mapPointsPath = Join-Path $dataDir "map_points.csv"
$ignoredPath = Join-Path $dataDir "ignored_notifications.jsonl"
$parserDiagnosticsPath = Join-Path $dataDir "parser_diagnostics.jsonl"
$hotZonesPath = Join-Path $dataDir "hot_zones.json"
$pidPath = Join-Path $dataDir "drivepilot_live_pids.json"
$hotZoneScript = Join-Path $scriptDir "update_hot_zones.ps1"

if (Test-Path -LiteralPath $hotZoneScript) {
    try {
        powershell -NoProfile -ExecutionPolicy Bypass -File $hotZoneScript -DataDir $dataDir | Out-Null
    }
    catch {}
}

function Test-HttpOk {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    }
    catch {
        return $false
    }
}

function Count-Lines {
    param([string]$Path, [switch]$SkipHeader)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $count = (Get-Content -Path $Path -Encoding UTF8 | Measure-Object -Line).Lines
    if ($SkipHeader -and $count -gt 0) { return $count - 1 }
    return $count
}

function Count-CsvRows {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        return @((Import-Csv -Path $Path -Encoding UTF8)).Count
    }
    catch {
        return Count-Lines $Path -SkipHeader
    }
}

function Get-FileLastWriteText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "尚未建立" }
    try {
        return (Get-Item -LiteralPath $Path).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch {
        return "無法讀取"
    }
}

function Show-Tail {
    param([string]$Path, [int]$Count = 5, [switch]$SkipHeader)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  尚未建立"
        return
    }
    $lines = @(Get-Content -Path $Path -Encoding UTF8)
    if ($SkipHeader) {
        if ($lines.Count -le 1) {
            Write-Host "  尚無資料"
            return
        }
        $lines = @($lines | Select-Object -Skip 1)
    }
    $tail = $lines | Select-Object -Last $Count
    if (-not $tail) {
        Write-Host "  尚無資料"
        return
    }
    foreach ($line in $tail) { Write-Host "  $line" }
}

function Show-RecentPlaces {
    param([string]$Path, [int]$Count = 5)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  尚未建立"
        return
    }
    try {
        $rows = @(Import-Csv -Path $Path -Encoding UTF8)
        $tail = $rows | Select-Object -Last $Count
        if (-not $tail) {
            Write-Host "  尚無資料"
            return
        }
        foreach ($row in $tail) {
            Write-Host "  $($row.timestamp) $($row.group) $($row.address)"
        }
    }
    catch {
        Show-Tail -Path $Path -Count $Count -SkipHeader
    }
}

function Show-RecentRawNotifications {
    param([string]$Path, [int]$Count = 10)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  尚未建立"
        return
    }
    $lines = @(Get-Content -Path $Path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last $Count)
    if (-not $lines) {
        Write-Host "  尚無資料"
        return
    }
    foreach ($line in $lines) {
        try {
            $item = $line | ConvertFrom-Json
            $raw = $item.raw
            $title = if ($raw -and $raw.PSObject.Properties.Name -contains "title") { [string]$raw.title } else { [string]$item.group }
            $text = if ($raw -and $raw.PSObject.Properties.Name -contains "text") { [string]$raw.text } else { [string]$item.text }
            $package = if ($raw -and $raw.PSObject.Properties.Name -contains "package") { [string]$raw.package } else { "" }
            $text = (($text -replace "[\r\n]+", " ") -replace "\s+", " ").Trim()
            if ($text.Length -gt 140) { $text = $text.Substring(0, 140) + "..." }
            Write-Host "  received_at: $($item.timestamp)"
            Write-Host "  title:       $title"
            Write-Host "  package:     $package"
            Write-Host "  text:        $text"
            Write-Host ""
        }
        catch {
            Write-Host "  $line"
        }
    }
}

function Show-RecentParserDiagnostics {
    param([string]$Path, [int]$Count = 20)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  尚未建立"
        return
    }
    $lines = @(Get-Content -Path $Path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last $Count)
    if (-not $lines) {
        Write-Host "  尚無資料"
        return
    }
    foreach ($line in $lines) {
        try {
            $item = $line | ConvertFrom-Json
            $text = (($item.text -replace "[\r\n]+", " ") -replace "\s+", " ").Trim()
            if ($text.Length -gt 120) { $text = $text.Substring(0, 120) + "..." }
            $addresses = @($item.matched_addresses)
            $hasAddress = if ([int]$item.address_count -gt 0) { "是" } else { "否" }
            $isDriverReply = if ($item.parser_result -eq "driver_reply" -or $item.kind -eq "driver_reply") { "是" } else { "否" }
            $isDescription = if ($item.parser_result -eq "description" -or $item.kind -eq "description") { "是" } else { "否" }
            $isIgnored = if ($item.parser_result -eq "ignored" -or -not [string]::IsNullOrWhiteSpace([string]$item.ignored_reason)) { "是" } else { "否" }
            Write-Host "  received_at: $($item.received_at)"
            Write-Host "  title:       $($item.title)"
            Write-Host "  package:     $($item.package)"
            Write-Host "  text_length: $($item.text_length)"
            Write-Host "  text:        $text"
            Write-Host "  parsed_addr: $hasAddress count=$($item.address_count) addresses=$($addresses -join ' | ')"
            Write-Host "  result:      $($item.parser_result) kind=$($item.kind) confidence=$($item.confidence)"
            Write-Host "  flags:       driver_reply=$isDriverReply description=$isDescription ignored=$isIgnored reason=$($item.ignored_reason)"
            Write-Host ""
        }
        catch {
            Write-Host "  $line"
        }
    }
}

Write-Host "DrivePilot Live v1 狀態"
$receiverOk = Test-HttpOk "http://127.0.0.1:$ReceiverPort/health"
$mapOk = Test-HttpOk "http://127.0.0.1:$MapPort/index.html"
$receiverPid = $null
$mapPid = $null
$receiverConnection = Get-NetTCPConnection -LocalPort $ReceiverPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$mapConnection = Get-NetTCPConnection -LocalPort $MapPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$receiverListening = $null -ne $receiverConnection
$mapListening = $null -ne $mapConnection
if ($receiverConnection) { $receiverPid = $receiverConnection.OwningProcess }
if ($mapConnection) { $mapPid = $mapConnection.OwningProcess }
if (-not $receiverPid) {
    $line = netstat -ano | Select-String ":$ReceiverPort\s+.*LISTENING\s+(\d+)" | Select-Object -First 1
    if ($line) {
        $receiverPid = $line.Matches[0].Groups[1].Value
        $receiverListening = $true
    }
}
if (-not $mapPid) {
    $line = netstat -ano | Select-String ":$MapPort\s+.*LISTENING\s+(\d+)" | Select-Object -First 1
    if ($line) {
        $mapPid = $line.Matches[0].Groups[1].Value
        $mapListening = $true
    }
}
if (Test-Path -LiteralPath $pidPath) {
    $pidInfo = Get-Content -Path $pidPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $receiverPid) { $receiverPid = $pidInfo.receiver_pid }
    if (-not $mapPid) { $mapPid = $pidInfo.map_pid }
}
Write-Host "通知接收器 8788: $(if ($receiverOk) { 'OK' } else { '未回應' })"
Write-Host "地圖服務 8790:     $(if ($mapOk) { 'OK' } else { '未回應' })"
Write-Host "8788 LISTENING:    $(if ($receiverListening) { 'YES' } else { 'NO' })"
Write-Host "8790 LISTENING:    $(if ($mapListening) { 'YES' } else { 'NO' })"
if (-not $receiverListening) {
    Write-Host "[ERROR] 8788 receiver not listening"
}
Write-Host "8788 PID:          $receiverPid"
Write-Host "8790 PID:          $mapPid"
if (Test-Path -LiteralPath $pidPath) {
    Write-Host "PID 檔紀錄時間:    $($pidInfo.started_at)"
}
Write-Host ""
Write-Host "資料檔更新時間"
Write-Host "notifications.jsonl LastWriteTime:       $(Get-FileLastWriteText $notificationsPath)"
Write-Host "parser_diagnostics.jsonl LastWriteTime:  $(Get-FileLastWriteText $parserDiagnosticsPath)"
Write-Host "places.csv LastWriteTime:                $(Get-FileLastWriteText $placesPath)"
Write-Host ""
Write-Host "資料筆數"
$processedCount = Count-Lines $notificationsPath
$ignoredCount = Count-Lines $ignoredPath
$receivedCount = $processedCount + $ignoredCount
Write-Host "已接收通知數:        $receivedCount"
Write-Host "已處理 LINE 通知數:  $processedCount"
Write-Host "已忽略非 LINE 通知數: $ignoredCount"
Write-Host "notifications.jsonl: $processedCount"
Write-Host "places.csv:          $(Count-CsvRows $placesPath)"
Write-Host "ignored_notifications.jsonl: $ignoredCount"
Write-Host "parser_diagnostics.jsonl: $(Count-Lines $parserDiagnosticsPath)"
Write-Host "map_points.csv:      $(Count-Lines $mapPointsPath -SkipHeader)"
Write-Host ""
Write-Host "最近 5 筆通知"
Show-Tail -Path $notificationsPath -Count 5
Write-Host ""
Write-Host "最近 10 筆 raw LINE 通知"
Show-RecentRawNotifications -Path $notificationsPath -Count 10
Write-Host ""
Write-Host "最近 20 筆 raw notification 診斷"
Show-RecentParserDiagnostics -Path $parserDiagnosticsPath -Count 20
Write-Host ""
Write-Host "最近 5 筆地址"
Show-RecentPlaces -Path $placesPath -Count 5
Write-Host ""
Write-Host "最近 5 筆被忽略通知"
Show-Tail -Path $ignoredPath -Count 5
Write-Host ""
Write-Host "最後一筆 LINE 通知時間"
if (Test-Path -LiteralPath $notificationsPath) {
    $lastNotification = @(Get-Content -Path $notificationsPath -Encoding UTF8 | Select-Object -Last 1)
    if ($lastNotification.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lastNotification[0])) {
        try {
            $lastObject = $lastNotification[0] | ConvertFrom-Json
            Write-Host "  $($lastObject.timestamp)"
        }
        catch {
            Write-Host "  無法解析"
        }
    }
    else {
        Write-Host "  尚無資料"
    }
}
else {
    Write-Host "  尚未建立"
}
Write-Host ""
Write-Host "最近 5 筆地圖點位"
Show-Tail -Path $mapPointsPath -Count 5 -SkipHeader
Write-Host ""
Write-Host "目前前三熱區"
if (Test-Path -LiteralPath $hotZonesPath) {
    try {
        $hotZones = Get-Content -Path $hotZonesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "最近 15 分鐘有效地址數: $($hotZones.recent_15min_valid_count)"
        Write-Host "最近 60 分鐘有效地址數: $($hotZones.recent_60min_valid_count)"
        Write-Host "市場熱度: $($hotZones.market_heat)"
        Write-Host "建議: $($hotZones.advice)"
        $topZones = @($hotZones.zones | Where-Object { $_.area -ne "未知" } | Select-Object -First 3)
        if ($topZones.Count -eq 0) {
            Write-Host "  目前熱區不足，仍需觀察"
        }
        else {
            foreach ($zone in $topZones) {
                Write-Host "  $($zone.area) score=$($zone.score) 15min=$($zone.count_15min) 60min=$($zone.count_60min) latest=$($zone.latest_address) $($zone.latest_seen_time)"
            }
        }
    }
    catch {
        Write-Host "  尚未建立"
    }
}
else {
    Write-Host "  尚未建立"
}
Write-Host ""
Write-Host "最近一次更新時間: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"









