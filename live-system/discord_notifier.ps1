param(
    [Parameter(Mandatory = $true)][ValidateSet("test", "high_confidence_address", "hot_zone_summary", "system_status", "dispatcher_alert")][string]$Type,
    [string]$Content = "",
    [string]$Address = "",
    [string]$Group = "",
    [string]$Kind = "",
    [string]$Confidence = "",
    [string]$SystemTime = "",
    [string]$NotificationTime = "",
    [string]$Note = "",
    [string]$PriceNote = "",
    [string]$Signature = "",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$dataDir = Join-Path $projectRoot "live-data"
$configPath = Join-Path $scriptDir "notification_config.json"
$modePath = Join-Path (Join-Path $projectRoot "config") "drivepilot_mode.json"
$logPath = Join-Path $dataDir "discord_push_log.jsonl"
$statePath = Join-Path $dataDir "discord_push_state.json"

function Add-Utf8Line {
    param([string]$Path, [string]$Line)
    [System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "notification_config.json not found"
    }
    return Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function get_drivepilot_mode {
    if (-not (Test-Path -LiteralPath $modePath)) { return "radar" }
    try {
        $modeConfig = Get-Content -Path $modePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $mode = [string]$modeConfig.mode
        if ($mode -in @("off", "quiet", "radar", "driving")) { return $mode }
    }
    catch {}
    return "radar"
}

function should_send_discord_notification {
    param($Event, [string]$Mode)
    $pushType = [string]$Event.type
    $confidenceValue = if ([string]::IsNullOrWhiteSpace([string]$Event.confidence)) { "high" } else { ([string]$Event.confidence).ToLowerInvariant() }

    if ($Mode -eq "off") {
        return [pscustomobject]@{ send = $false; reason = "mode_off" }
    }

    if ($pushType -eq "hot_zone_summary") {
        return [pscustomobject]@{ send = ($Mode -in @("quiet", "radar", "driving")); reason = "hotzone" }
    }

    if ($pushType -eq "dispatcher_alert") {
        return [pscustomobject]@{ send = ($Mode -in @("quiet", "radar", "driving")); reason = "personal_alert" }
    }

    if ($pushType -eq "high_confidence_address") {
        return [pscustomobject]@{ send = $false; reason = "locatable_signal_not_pushed" }
    }

    if ($pushType -eq "test") {
        return [pscustomobject]@{ send = ($Mode -ne "off"); reason = "test" }
    }

    return [pscustomobject]@{ send = $false; reason = "type_filtered" }
}

function New-PushState {
    return [pscustomobject]@{
        last_high_confidence_pushes = [pscustomobject]@{}
        last_hot_zone_summary_time = ""
        last_hot_zone_summary_signature = ""
    }
}

function Read-PushState {
    if (-not (Test-Path -LiteralPath $statePath)) { return New-PushState }
    try {
        $state = Get-Content -Path $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not ($state.PSObject.Properties.Name -contains "last_high_confidence_pushes")) {
            $state | Add-Member -NotePropertyName "last_high_confidence_pushes" -NotePropertyValue ([pscustomobject]@{})
        }
        if (-not ($state.PSObject.Properties.Name -contains "last_hot_zone_summary_time")) {
            $state | Add-Member -NotePropertyName "last_hot_zone_summary_time" -NotePropertyValue ""
        }
        if (-not ($state.PSObject.Properties.Name -contains "last_hot_zone_summary_signature")) {
            $state | Add-Member -NotePropertyName "last_hot_zone_summary_signature" -NotePropertyValue ""
        }
        return $state
    }
    catch {
        return New-PushState
    }
}

function Save-PushState {
    param($State)
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    [System.IO.File]::WriteAllText($statePath, ($State | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)
}

function Test-RecentTimestamp {
    param([string]$Timestamp, [int]$Minutes)
    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return $false }
    try {
        $seen = [datetime]::Parse($Timestamp)
        return ((Get-Date) - $seen).TotalMinutes -le $Minutes
    }
    catch {
        return $false
    }
}

function Get-StateKey {
    param([string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Add-MentionIfNeeded {
    param($Config, [string]$PushType, [string]$Message)
    $mentionId = ""
    if ($Config.PSObject.Properties.Name -contains "discord_mention_user_id") {
        $mentionId = [string]$Config.discord_mention_user_id
    }
    if ([string]::IsNullOrWhiteSpace($mentionId)) { return $Message }
    if ($PushType -in @("high_confidence_address", "hot_zone_summary", "dispatcher_alert")) {
        return "<@$mentionId>" + [Environment]::NewLine + $Message
    }
    return $Message
}

function Send-Discord {
    param([string]$WebhookUrl, [string]$Message)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        throw "Discord webhook URL is empty for $Type"
    }
    $body = @{ content = $Message } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType "application/json; charset=utf-8" -Body $body | Out-Null
}

$mode = get_drivepilot_mode
$modeDecision = should_send_discord_notification -Mode $mode -Event ([pscustomobject]@{
    type = $Type
    confidence = $Confidence
    kind = $Kind
})
if (-not [bool]$modeDecision.send) {
    Write-Host "[DrivePilot] discord=skip reason=$($modeDecision.reason) mode=$mode kind=$Kind confidence=$Confidence"
    exit 0
}

$config = Read-Config
if (-not $Force -and -not [bool]$config.enable_discord_push) {
    Write-Host "[DrivePilot] discord=skip reason=enable_discord_push_false mode=$mode"
    exit 0
}

$webhook = [string]$config.discord_webhooks.$Type
Write-Host "[DrivePilot] webhook_loaded=$(-not [string]::IsNullOrWhiteSpace($webhook)) webhook_target=$Type"
$rules = $config.discord_push_rules
$dedupeMinutes = if ($rules -and $rules.dedupe_minutes) { [int]$rules.dedupe_minutes } else { 10 }
$summaryInterval = if ($rules -and $rules.hot_zone_summary_interval_minutes) { [int]$rules.hot_zone_summary_interval_minutes } else { 15 }
$message = $Content
$key = "$Type|$Content"
$state = Read-PushState

if ($Type -eq "test") {
    $message = "DrivePilot Discord 測試通知成功"
    $key = "test"
}
elseif ($Type -eq "high_confidence_address") {
    if ($rules -and -not [bool]$rules.push_high_confidence_address) {
        Write-Host "SKIP: push_high_confidence_address=false"
        exit 0
    }
    $key = "high_confidence_address|$Group|$Address"
    $stateKey = Get-StateKey -Value $key
    $lastPushes = $state.last_high_confidence_pushes
    $lastPushNames = @($lastPushes.PSObject.Properties | ForEach-Object { $_.Name })
    $lastTime = if ($lastPushNames -contains $stateKey) { [string]$lastPushes.$stateKey } else { "" }
    if (-not $Force -and (Test-RecentTimestamp -Timestamp $lastTime -Minutes $dedupeMinutes)) {
        Write-Host "[DrivePilot] discord=skip reason=dedupe_high_confidence mode=$mode kind=$Kind confidence=$Confidence"
        exit 0
    }
    $searchUrl = "https://www.google.com/maps/search/?api=1&query=$([uri]::EscapeDataString($Address))"
    $navUrl = "https://www.google.com/maps/dir/?api=1&destination=$([uri]::EscapeDataString($Address))"
    if (-not [string]::IsNullOrWhiteSpace($Content)) {
        $message = $Content
    }
    else {
        $message = @(
            "【DrivePilot 可定位訊號】",
            "地址：$Address",
            "來源：$Group",
            $(if ($Kind) { "kind：$Kind" } else { "" }),
            $(if ($Confidence) { "confidence：$Confidence" } else { "confidence：high" }),
            $(if ($NotificationTime) { "通知時間：$NotificationTime" } else { "" }),
            "系統時間：$SystemTime",
            $(if ($Note) { "備註：$Note" } else { "" }),
            $(if ($PriceNote) { "低消/價格：$PriceNote" } else { "" }),
            "Google Maps 搜尋：$searchUrl",
            "Google Maps 導航：$navUrl"
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $message = $message -join [Environment]::NewLine
    }
}
elseif ($Type -eq "hot_zone_summary") {
    if ($rules -and -not [bool]$rules.push_hot_zone_summary) {
        Write-Host "SKIP: push_hot_zone_summary=false"
        exit 0
    }
    $key = "hot_zone_summary"
    $currentSignature = if ([string]::IsNullOrWhiteSpace($Signature)) { Get-StateKey -Value $Content } else { $Signature }
    $sameSignature = [string]$state.last_hot_zone_summary_signature -eq $currentSignature
    $recentSummary = Test-RecentTimestamp -Timestamp ([string]$state.last_hot_zone_summary_time) -Minutes $summaryInterval
    if (-not $Force -and $sameSignature -and $recentSummary) {
        Write-Host "[DrivePilot] discord=skip reason=dedupe_hotzone mode=$mode"
        exit 0
    }
}
elseif ($Type -eq "system_status") {
    if ($rules -and -not [bool]$rules.push_system_status) {
        Write-Host "SKIP: push_system_status=false"
        exit 0
    }
    $key = "system_status|$(Get-Date -Format 'yyyyMMddHHmmss')"
}

$message = Add-MentionIfNeeded -Config $config -PushType $Type -Message $message
try {
    Send-Discord -WebhookUrl $webhook -Message $message
    Write-Host "[DrivePilot] discord=sent reason=$($modeDecision.reason) mode=$mode"
}
catch {
    $statusCode = ""
    if ($_.Exception.Response) {
        try { $statusCode = [string][int]$_.Exception.Response.StatusCode } catch {}
    }
    Write-Host "[DrivePilot] discord=failed status_code=$statusCode error=$($_.Exception.Message)"
    throw
}

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
if ($Type -eq "high_confidence_address") {
    $stateKey = Get-StateKey -Value $key
    $state.last_high_confidence_pushes | Add-Member -NotePropertyName $stateKey -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
}
elseif ($Type -eq "hot_zone_summary") {
    $state.last_hot_zone_summary_time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $state.last_hot_zone_summary_signature = if ([string]::IsNullOrWhiteSpace($Signature)) { Get-StateKey -Value $Content } else { $Signature }
}
Save-PushState -State $state

if (-not (Test-Path -LiteralPath $logPath)) { New-Item -ItemType File -Path $logPath | Out-Null }
Add-Utf8Line -Path $logPath -Line ([pscustomobject]@{
    timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    type = $Type
    key = $key
} | ConvertTo-Json -Compress)
Write-Host "PASS: Discord message sent ($Type)"
