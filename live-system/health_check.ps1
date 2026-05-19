param(
    [Alias("threshold-minutes", "ThresholdMinutes")]
    [int]$AlertAfterMinutes = 20,
    [Alias("cooldown-minutes")]
    [int]$CooldownMinutes = 30,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$dataDir = Join-Path $projectRoot "live-data"
$runtimeDir = Join-Path $projectRoot "runtime"
$notificationsPath = Join-Path $dataDir "notifications.jsonl"
$configPath = Join-Path $scriptDir "notification_config.json"
$statePath = Join-Path $runtimeDir "health_state.json"

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-HealthLog {
    param([string]$Message)
    Write-Host $Message
}

function Read-HealthState {
    $state = Read-JsonFile -Path $statePath
    if ($null -eq $state) {
        return [pscustomobject]@{
            alert_active = $false
            last_alert_sent_at = ""
            last_recovery_sent_at = ""
            last_seen_timestamp = ""
        }
    }
    foreach ($name in @("alert_active", "last_alert_sent_at", "last_recovery_sent_at", "last_seen_timestamp")) {
        if (-not ($state.PSObject.Properties.Name -contains $name)) {
            $defaultValue = ""
            if ($name -eq "alert_active") {
                $defaultValue = $false
            }
            $state | Add-Member -NotePropertyName $name -NotePropertyValue $defaultValue
        }
    }
    return $state
}

function Save-HealthState {
    param($State)
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    [System.IO.File]::WriteAllText($statePath, ($State | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
}

function Get-NotificationTimestamp {
    param($Entry)
    foreach ($name in @("timestamp", "received_at", "time")) {
        if ($Entry.PSObject.Properties.Name -contains $name) {
            $value = [string]($Entry.$name)
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
    }
    return ""
}

function Get-LastNotificationTime {
    if (-not (Test-Path -LiteralPath $notificationsPath)) { return $null }

    $lines = Get-Content -Path $notificationsPath -Encoding UTF8 -Tail 80
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = [string]$lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = $line | ConvertFrom-Json
            $timestamp = Get-NotificationTimestamp -Entry $entry
            if ([string]::IsNullOrWhiteSpace($timestamp)) { continue }
            return [datetime]::Parse($timestamp)
        }
        catch {
            continue
        }
    }
    return $null
}

function Test-CooldownExpired {
    param([string]$Timestamp, [int]$Minutes)
    if ($Force) { return $true }
    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return $true }
    try {
        return ((Get-Date) - [datetime]::Parse($Timestamp)).TotalMinutes -ge $Minutes
    }
    catch {
        return $true
    }
}

function Send-HealthDiscord {
    param([string]$Message)

    $config = Read-JsonFile -Path $configPath
    if ($null -eq $config) {
        Write-HealthLog "[DrivePilot Health] discord=skip reason=config_not_found"
        return
    }

    $webhook = ""
    if ($config.PSObject.Properties.Name -contains "discord_webhooks") {
        $hooks = $config.discord_webhooks
        foreach ($name in @("system_status", "dashboard", "test")) {
            if ($hooks.PSObject.Properties.Name -contains $name) {
                $candidate = [string]($hooks.$name)
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $webhook = $candidate
                    break
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($webhook)) {
        Write-HealthLog "[DrivePilot Health] discord=skip reason=webhook_empty"
        return
    }

    # Health alerts intentionally bypass DrivePilot push mode. Even when mode=off,
    # this warning is meant to catch broken MacroDroid / network / receiver paths.
    $body = @{ content = $Message } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri $webhook -Method Post -ContentType "application/json; charset=utf-8" -Body $body | Out-Null
        Write-HealthLog "[DrivePilot Health] discord=sent"
        return $true
    }
    catch {
        $statusCode = "unknown"
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        $errorMessage = $_.Exception.Message
        Write-HealthLog "[DrivePilot Health] discord=failed status_code=$statusCode error=$errorMessage"
        return $false
    }
}

function Invoke-HealthCheck {
    $state = Read-HealthState
    $now = Get-Date
    $lastSeen = Get-LastNotificationTime
    $shouldAlert = $false
    $lastSeenText = "none"

    if ($null -eq $lastSeen) {
        $shouldAlert = $true
    }
    else {
        $ageMinutes = ($now - $lastSeen).TotalMinutes
        $shouldAlert = $ageMinutes -gt $AlertAfterMinutes
        $lastSeenText = $lastSeen.ToString("yyyy-MM-dd HH:mm:ss")
    }

    $state.last_seen_timestamp = $lastSeenText

    if ($shouldAlert) {
        $alertReason = "no_notifications_$($AlertAfterMinutes)min"
        Write-HealthLog "[DrivePilot Health] status=alert reason=$alertReason"
        $lastAlertSentAt = [string]($state.last_alert_sent_at)
        $canSendAlert = Test-CooldownExpired -Timestamp $lastAlertSentAt -Minutes $CooldownMinutes
        if ($canSendAlert) {
            $sent = Send-HealthDiscord -Message "DrivePilot Health Alert`n已超過 $AlertAfterMinutes 分鐘沒有收到 LINE 通知，請檢查 MacroDroid / 手機網路 / 8788。"
            if ($sent) {
                $state.last_alert_sent_at = $now.ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        else {
            Write-HealthLog "[DrivePilot Health] discord=skip reason=alert_cooldown"
        }
        $state.alert_active = $true
        Save-HealthState -State $state
        return
    }

    Write-HealthLog "[DrivePilot Health] status=ok last_seen=$lastSeenText"
    if ([bool]($state.alert_active)) {
        Write-HealthLog "[DrivePilot Health] status=recovered"
        $lastRecoverySentAt = [string]($state.last_recovery_sent_at)
        $canSendRecovery = Test-CooldownExpired -Timestamp $lastRecoverySentAt -Minutes $CooldownMinutes
        if ($canSendRecovery) {
            $sent = Send-HealthDiscord -Message "DrivePilot Health OK`n已恢復收到 LINE 通知。"
            if ($sent) {
                $state.last_recovery_sent_at = $now.ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        else {
            Write-HealthLog "[DrivePilot Health] discord=skip reason=recovery_cooldown"
        }
    }
    $state.alert_active = $false
    Save-HealthState -State $state
}

Invoke-HealthCheck
