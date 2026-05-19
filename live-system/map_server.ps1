param(
    [int]$Port = 8790,
    [string]$ListenAddress = "0.0.0.0",
    [string]$Root = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Root -eq ".") {
    $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\live-map"
}

$resolvedRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$resolvedDataRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\live-data"))
$statusPath = Join-Path $projectRoot "live-data\map_server_status.json"
$drivepilotStatusPath = Join-Path $projectRoot "live-data\drivepilot_status.json"
$drivepilotModePath = Join-Path $projectRoot "config\drivepilot_mode.json"
$notificationsPath = Join-Path $projectRoot "live-data\notifications.jsonl"
$marketReportPath = Join-Path $projectRoot "live-data\market_report.json"
$marketReportBuilderPath = Join-Path $projectRoot "live-system\build_market_report.py"
$script:marketReportRefreshRunning = $false
@{
    started_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    port = $Port
    listen_address = $ListenAddress
    root = $resolvedRoot
} | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($ListenAddress), $Port)
$listener.Start()

function Get-ContentType {
    param([string]$Path)
    switch -Regex ($Path) {
        "\.html?$" { return "text/html; charset=utf-8" }
        "\.css$" { return "text/css; charset=utf-8" }
        "\.js$" { return "text/javascript; charset=utf-8" }
        "\.json$" { return "application/json; charset=utf-8" }
        "\.csv$" { return "text/csv; charset=utf-8" }
        "\.kml$" { return "application/vnd.google-earth.kml+xml; charset=utf-8" }
        default { return "application/octet-stream" }
    }
}

function Read-Request {
    param($Client)
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 3000
    $buffer = New-Object byte[] 4096
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { return $null }
    $raw = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    while ($raw -notmatch "`r`n`r`n") {
        $readMore = $stream.Read($buffer, 0, $buffer.Length)
        if ($readMore -le 0) { break }
        $raw += [System.Text.Encoding]::UTF8.GetString($buffer, 0, $readMore)
    }
    $line = ($raw -split "`r`n")[0]
    $parts = $line -split " "
    if ($parts.Count -lt 2) { return $null }
    $body = ""
    $sections = $raw -split "`r`n`r`n", 2
    if ($sections.Count -gt 1) { $body = $sections[1] }
    $contentLength = 0
    foreach ($headerLine in ($raw -split "`r`n")) {
        if ($headerLine -match "^Content-Length:\s*(\d+)") {
            $contentLength = [int]$matches[1]
            break
        }
    }
    while ($contentLength -gt 0 -and [System.Text.Encoding]::UTF8.GetByteCount($body) -lt $contentLength) {
        $readMore = $stream.Read($buffer, 0, $buffer.Length)
        if ($readMore -le 0) { break }
        $body += [System.Text.Encoding]::UTF8.GetString($buffer, 0, $readMore)
    }
    return [pscustomobject]@{
        Method = $parts[0]
        Path = ($parts[1] -split "\?")[0]
        Body = $body
    }
}

function Send-Response {
    param(
        $Client,
        [int]$Status,
        [string]$ContentType,
        [byte[]]$Body
    )

    $reason = switch ($Status) {
        200 { "OK" }
        400 { "Bad Request" }
        405 { "Method Not Allowed" }
        409 { "Conflict" }
        404 { "Not Found" }
        403 { "Forbidden" }
        500 { "Internal Server Error" }
        default { "OK" }
    }
    $header = "HTTP/1.1 $Status $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream = $Client.GetStream()
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($Body, 0, $Body.Length)
    $stream.Flush()
}

function New-JsonResponse {
    param(
        [bool]$Ok,
        [string]$Message,
        [string]$Error = "",
        [int]$ExitCode = 0
    )

    $generatedAt = ""
    if (Test-Path -LiteralPath $marketReportPath) {
        try {
            $report = Get-Content -Path $marketReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($report.PSObject.Properties.Name -contains "generated_at") {
                $generatedAt = [string]$report.generated_at
            }
        }
        catch {}
    }

    return ([pscustomobject]@{
        ok = $Ok
        message = $Message
        generated_at = $generatedAt
        path = "live-data/market_report.json"
        error = $Error
        exit_code = $ExitCode
    } | ConvertTo-Json -Compress)
}

function Invoke-MarketReportRefresh {
    if ($script:marketReportRefreshRunning) {
        return [pscustomobject]@{
            Status = 409
            Json = (New-JsonResponse -Ok $false -Message "更新中" -Error "refresh_in_progress")
        }
    }

    $script:marketReportRefreshRunning = $true
    try {
        if (-not (Test-Path -LiteralPath $marketReportBuilderPath -PathType Leaf)) {
            return [pscustomobject]@{
                Status = 500
                Json = (New-JsonResponse -Ok $false -Message "更新失敗" -Error "builder_not_found")
            }
        }

        $python = (Get-Command python -ErrorAction SilentlyContinue)
        if ($null -eq $python) {
            return [pscustomobject]@{
                Status = 500
                Json = (New-JsonResponse -Ok $false -Message "更新失敗" -Error "python_not_found")
            }
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $python.Source
        $startInfo.Arguments = "`"$marketReportBuilderPath`""
        $startInfo.WorkingDirectory = $projectRoot
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -eq 0) {
            Write-Host "[DrivePilot Market Report] refresh_ok output=$($stdout.Trim())"
            return [pscustomobject]@{
                Status = 200
                Json = (New-JsonResponse -Ok $true -Message "更新完成" -ExitCode $process.ExitCode)
            }
        }

        $errorParts = @($stderr.Trim(), $stdout.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $errorText = $errorParts -join " | "
        if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = "builder_failed" }
        Write-Host "[DrivePilot Market Report] refresh_failed exit=$($process.ExitCode) error=$errorText"
        return [pscustomobject]@{
            Status = 500
            Json = (New-JsonResponse -Ok $false -Message "更新失敗" -Error $errorText -ExitCode $process.ExitCode)
        }
    }
    catch {
        return [pscustomobject]@{
            Status = 500
            Json = (New-JsonResponse -Ok $false -Message "更新失敗" -Error $_.Exception.Message)
        }
    }
    finally {
        $script:marketReportRefreshRunning = $false
    }
}

function Get-DrivePilotMode {
    if (-not (Test-Path -LiteralPath $drivepilotModePath)) { return "radar" }
    try {
        $modeConfig = Get-Content -Path $drivepilotModePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $mode = [string]$modeConfig.mode
        if ($mode -in @("off", "quiet", "radar", "driving")) { return $mode }
    }
    catch {}
    return "radar"
}

function Get-LastNotificationTime {
    if (-not (Test-Path -LiteralPath $notificationsPath)) { return "" }
    try {
        $lines = Get-Content -Path $notificationsPath -Encoding UTF8 -Tail 80
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = [string]$lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                foreach ($name in @("timestamp", "received_at", "time")) {
                    if ($entry.PSObject.Properties.Name -contains $name) {
                        $value = [string]($entry.$name)
                        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
                    }
                }
            }
            catch {}
        }
        return (Get-Item -LiteralPath $notificationsPath).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch {
        return ""
    }
}

function New-DrivePilotStatusJson {
    $mode = Get-DrivePilotMode
    $lastNotificationTime = Get-LastNotificationTime
    $healthStatus = "unknown"
    if (-not [string]::IsNullOrWhiteSpace($lastNotificationTime)) {
        try {
            $lastSeen = [datetime]::Parse($lastNotificationTime)
            if (((Get-Date) - $lastSeen).TotalMinutes -gt 20) {
                $healthStatus = "alert"
            }
            else {
                $healthStatus = "ok"
            }
        }
        catch {
            $healthStatus = "unknown"
        }
    }

    $status = [pscustomobject]@{
        mode = $mode
        health_status = $healthStatus
        last_notification_time = $lastNotificationTime
    }
    $json = $status | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($drivepilotStatusPath, $json, [System.Text.Encoding]::UTF8)
    return $json
}

function Set-DrivePilotMode {
    param([string]$Mode)
    if ($Mode -notin @("off", "quiet", "radar", "driving")) {
        throw "invalid mode"
    }
    $configDir = Split-Path -Parent $drivepilotModePath
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    }
    $json = [pscustomobject]@{ mode = $Mode } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($drivepilotModePath, $json, [System.Text.Encoding]::UTF8)
    New-DrivePilotStatusJson | Out-Null
    Write-Host "[DrivePilot] mode_changed=$Mode source=mobile_dashboard"
}

function Get-ObjectValue {
    param(
        $Object,
        [string[]]$Names
    )
    if ($null -eq $Object) { return "" }
    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
    }
    return ""
}

function Get-NotificationDate {
    param($Entry)
    $value = Get-ObjectValue -Object $Entry -Names @("timestamp", "time", "created_at", "received_at")
    if ([string]::IsNullOrWhiteSpace([string]$value)) { return $null }
    try {
        return [datetime]::Parse([string]$value)
    }
    catch {
        return $null
    }
}

function Test-TagValue {
    param(
        $Entry,
        [string]$Value
    )
    if ($null -eq $Entry) { return $false }
    foreach ($name in @("kind", "type")) {
        if ($Entry.PSObject.Properties.Name -contains $name -and ([string]$Entry.$name) -eq $Value) {
            return $true
        }
    }
    if ($Entry.PSObject.Properties.Name -contains "tags") {
        $tags = $Entry.tags
        if ($tags -is [array] -and $tags -contains $Value) { return $true }
        if ($tags -is [string] -and $tags -match [regex]::Escape($Value)) { return $true }
    }
    return $false
}

function Test-DispatcherPrivate {
    param($Entry)
    if ($Entry.PSObject.Properties.Name -contains "dispatcher_private" -and [bool]$Entry.dispatcher_private) { return $true }
    return (Test-TagValue -Entry $Entry -Value "dispatcher_private")
}

function Test-HotzoneSignal {
    param($Entry)
    if ($Entry.PSObject.Properties.Name -contains "hotzone" -and [bool]$Entry.hotzone) { return $true }
    return (Test-TagValue -Entry $Entry -Value "hotzone")
}

function Add-Count {
    param(
        [hashtable]$Table,
        [string]$Key,
        [int]$Amount = 1
    )
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    if (-not $Table.ContainsKey($Key)) { $Table[$Key] = 0 }
    $Table[$Key] += $Amount
}

function Get-TopRows {
    param(
        [hashtable]$Table,
        [int]$Top = 3
    )
    return @($Table.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $Top | ForEach-Object {
        [pscustomobject]@{
            name = [string]$_.Key
            count = [int]$_.Value
        }
    })
}

function Get-DrivePilotAnalysisJson {
    $status = $null
    try {
        if (Test-Path -LiteralPath $drivepilotStatusPath) {
            $status = Get-Content -Path $drivepilotStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
    catch {
        $status = $null
    }
    if ($null -eq $status) {
        try { $status = New-DrivePilotStatusJson | ConvertFrom-Json } catch { $status = $null }
    }

    $allEntries = @()
    $skippedInvalid = 0
    if (Test-Path -LiteralPath $notificationsPath) {
        try {
            foreach ($line in (Get-Content -Path $notificationsPath -Encoding UTF8 -Tail 5000)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $allEntries += ($line | ConvertFrom-Json)
                }
                catch {
                    $skippedInvalid += 1
                }
            }
        }
        catch {}
    }

    $now = Get-Date
    $cutoff = $now.AddMinutes(-60)
    $recent = @()
    $unknownTimeCount = 0
    $lastNotificationTime = ""
    $lastDate = $null
    foreach ($entry in $allEntries) {
        $date = Get-NotificationDate -Entry $entry
        if ($null -eq $date) {
            $unknownTimeCount += 1
            continue
        }
        if ($null -eq $lastDate -or $date -gt $lastDate) {
            $lastDate = $date
            $lastNotificationTime = $date.ToString("yyyy-MM-dd HH:mm:ss")
        }
        if ($date -ge $cutoff -and $date -le $now.AddMinutes(1)) {
            $recent += [pscustomobject]@{ entry = $entry; time = $date }
        }
    }

    $areaCounts = @{}
    $hotzoneAreaCounts = @{}
    $groupCounts = @{}
    $dispatcherCount = 0
    $hotzoneCount = 0
    $highValue = @()
    foreach ($item in $recent) {
        $entry = $item.entry
        $isDispatcher = Test-DispatcherPrivate -Entry $entry
        $isHotzone = Test-HotzoneSignal -Entry $entry
        if ($isDispatcher) { $dispatcherCount += 1 }
        if ($isHotzone) { $hotzoneCount += 1 }

        $area = [string](Get-ObjectValue -Object $entry -Names @("area", "place", "landmark", "address"))
        Add-Count -Table $areaCounts -Key $area
        if ($isHotzone) { Add-Count -Table $hotzoneAreaCounts -Key $area }

        $group = [string](Get-ObjectValue -Object $entry -Names @("group_name", "source", "title", "sender"))
        if ([string]::IsNullOrWhiteSpace($group)) { $group = "未知來源" }
        Add-Count -Table $groupCounts -Key $group

        if ($isDispatcher -or $isHotzone) {
            $typeText = if ($isDispatcher) { "個人提醒" } else { "熱區" }
            $placeText = [string](Get-ObjectValue -Object $entry -Names @("area", "place", "landmark", "address"))
            if ([string]::IsNullOrWhiteSpace($placeText)) {
                $placeText = [string](Get-ObjectValue -Object $entry -Names @("text", "message", "raw_text"))
            }
            $highValue += [pscustomobject]@{
                time = $item.time.ToString("yyyy-MM-dd HH:mm:ss")
                source = $group
                place = $placeText
                type = $typeText
            }
        }
    }

    $hotAreas = @($areaCounts.GetEnumerator() | Sort-Object @{ Expression = { if ($hotzoneAreaCounts.ContainsKey($_.Key)) { $hotzoneAreaCounts[$_.Key] } else { 0 } }; Descending = $true }, @{ Expression = { $_.Value }; Descending = $true } | Select-Object -First 3 | ForEach-Object {
        [pscustomobject]@{
            name = [string]$_.Key
            count = [int]$_.Value
        }
    })

    $systemStatus = if ($status -and $status.health_status) { [string]$status.health_status } else { "未知" }
    $marketStatus = "觀察中"
    if ($systemStatus -eq "alert") {
        $marketStatus = "系統注意"
    }
    elseif ($recent.Count -le 1) {
        $marketStatus = "冷"
    }
    elseif ($dispatcherCount -gt 0 -or $hotzoneCount -gt 0 -or $recent.Count -ge 30) {
        $marketStatus = "活躍"
    }
    elseif ($recent.Count -ge 10) {
        $marketStatus = "升溫中"
    }

    $analysis = [pscustomobject]@{
        ok = $true
        generated_at = $now.ToString("yyyy-MM-dd HH:mm:ss")
        window_minutes = 60
        market_status = $marketStatus
        system_status = $systemStatus
        last_notification_time = $lastNotificationTime
        total_recent_notifications = $recent.Count
        dispatcher_private_count = $dispatcherCount
        hotzone_count = $hotzoneCount
        hot_areas_top3 = $hotAreas
        active_groups_top3 = @(Get-TopRows -Table $groupCounts -Top 3)
        high_value_recent5 = @($highValue | Sort-Object -Property time -Descending | Select-Object -First 5)
        skipped_unknown_time = $unknownTimeCount
        skipped_invalid_lines = $skippedInvalid
    }
    return ($analysis | ConvertTo-Json -Depth 6 -Compress)
}

Write-Host "Map server running at http://$ListenAddress`:$Port/"
Write-Host "Serving: $resolvedRoot"
Write-Host "Open: http://127.0.0.1:$Port/index.html"
if ($ListenAddress -eq "0.0.0.0") {
    Write-Host "LAN access: http://<computer-ip>:$Port/index.html"
}
Write-Host "Press Ctrl+C to stop."

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $request = Read-Request -Client $client
            if ($null -eq $request) {
                $body = [System.Text.Encoding]::UTF8.GetBytes("Not found")
                Send-Response -Client $client -Status 404 -ContentType "text/plain; charset=utf-8" -Body $body
                continue
            }

            $requestPath = $request.Path
            if ($requestPath -match "^https?://") {
                $requestPath = ([uri]$requestPath).AbsolutePath
            }
            $urlPath = [uri]::UnescapeDataString($requestPath.TrimStart("/"))
            if ([string]::IsNullOrWhiteSpace($urlPath)) {
                $urlPath = "index.html"
            }

            if ($request.Method -eq "POST" -and $urlPath -eq "api/mode") {
                try {
                    $payload = $request.Body | ConvertFrom-Json
                    $mode = [string]$payload.mode
                    Set-DrivePilotMode -Mode $mode
                    $json = [pscustomobject]@{ ok = $true; mode = $mode } | ConvertTo-Json -Compress
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-Response -Client $client -Status 200 -ContentType "application/json; charset=utf-8" -Body $body
                }
                catch {
                    $json = [pscustomobject]@{ ok = $false; error = "invalid mode" } | ConvertTo-Json -Compress
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-Response -Client $client -Status 400 -ContentType "application/json; charset=utf-8" -Body $body
                }
                continue
            }

            if ($request.Method -eq "POST" -and $urlPath -eq "api/refresh-market-report") {
                $result = Invoke-MarketReportRefresh
                $body = [System.Text.Encoding]::UTF8.GetBytes($result.Json)
                Send-Response -Client $client -Status $result.Status -ContentType "application/json; charset=utf-8" -Body $body
                continue
            }

            if ($request.Method -ne "GET") {
                $body = [System.Text.Encoding]::UTF8.GetBytes("Not found")
                Send-Response -Client $client -Status 404 -ContentType "text/plain; charset=utf-8" -Body $body
                continue
            }

            if ($urlPath -eq "api/analyze") {
                try {
                    $json = Get-DrivePilotAnalysisJson
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-Response -Client $client -Status 200 -ContentType "application/json; charset=utf-8" -Body $body
                }
                catch {
                    $json = [pscustomobject]@{ ok = $false; error = "analysis_failed" } | ConvertTo-Json -Compress
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-Response -Client $client -Status 400 -ContentType "application/json; charset=utf-8" -Body $body
                    Write-Host "[DrivePilot Analyze] failed=$($_.Exception.Message)"
                }
                continue
            }

            if ($urlPath -eq "live-data/drivepilot_status.json" -or $urlPath -eq "data/drivepilot_status.json") {
                $json = New-DrivePilotStatusJson
                $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                Send-Response -Client $client -Status 200 -ContentType "application/json; charset=utf-8" -Body $body
                continue
            }

            $serveRoot = $resolvedRoot
            if ($urlPath -like "data/*") {
                $serveRoot = $resolvedDataRoot
                $urlPath = $urlPath.Substring(5)
            }
            $target = [System.IO.Path]::GetFullPath((Join-Path $serveRoot $urlPath))
            @{
                at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                request_path = $request.Path
                parsed_path = $urlPath
                target = $target
                root = $serveRoot
                exists = (Test-Path -LiteralPath $target -PathType Leaf)
            } | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8
            if (-not $target.StartsWith($serveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $body = [System.Text.Encoding]::UTF8.GetBytes("Forbidden")
                Send-Response -Client $client -Status 403 -ContentType "text/plain; charset=utf-8" -Body $body
                continue
            }

            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                $body = [System.Text.Encoding]::UTF8.GetBytes("Not found: $target`nRoot: $serveRoot")
                Send-Response -Client $client -Status 404 -ContentType "text/plain; charset=utf-8" -Body $body
                continue
            }

            $bodyBytes = [System.IO.File]::ReadAllBytes($target)
            Send-Response -Client $client -Status 200 -ContentType (Get-ContentType $target) -Body $bodyBytes
        }
        catch {
            try {
                $message = "Request error"
                $body = [System.Text.Encoding]::UTF8.GetBytes($message)
                Send-Response -Client $client -Status 400 -ContentType "text/plain; charset=utf-8" -Body $body
            }
            catch {}
            Write-Host "[DrivePilot Map] request_error=$($_.Exception.Message)"
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
}









