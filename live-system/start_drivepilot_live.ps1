param(
    [int]$MapPort = 8790,
    [int]$ReceiverPort = 8788,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$dataDir = Join-Path $projectRoot "live-data"
$mapDir = Join-Path $projectRoot "live-map"
$pidPath = Join-Path $dataDir "drivepilot_live_pids.json"
$logsDir = Join-Path $dataDir "logs"

New-Item -ItemType Directory -Force -Path $dataDir, $logsDir | Out-Null

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

function Get-LanIp {
    $addresses = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object {
            $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork `
                -and -not $_.IPAddressToString.StartsWith("127.") `
                -and -not $_.IPAddressToString.StartsWith("169.254.")
        } |
        ForEach-Object { $_.IPAddressToString }
    $preferred = @($addresses | Where-Object { $_ -like "192.168.*" } | Select-Object -First 1)
    if ($preferred.Count -gt 0) { return $preferred[0] }
    $preferred = @($addresses | Where-Object { $_ -like "10.*" } | Select-Object -First 1)
    if ($preferred.Count -gt 0) { return $preferred[0] }
    $preferred = @($addresses | Where-Object {
        if ($_ -match "^172\.(\d+)\.") {
            $n = [int]$matches[1]
            return ($n -ge 16 -and $n -le 31)
        }
        return $false
    } | Select-Object -First 1)
    if ($preferred.Count -gt 0) { return $preferred[0] }
    $preferred = @($addresses | Where-Object { $_ -notlike "100.*" } | Select-Object -First 1)
    if ($preferred.Count -gt 0) { return $preferred[0] }
    if ($addresses) { return $addresses[0] }
    return "電腦區網IP"
}

function Stop-PortListener {
    param([int]$Port)
    $connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($connection in $connections) {
        if ($connection.OwningProcess -and (Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue)) {
            Write-Host "Port $Port is occupied by PID $($connection.OwningProcess). Restarting it for DrivePilot Live."
            Stop-Process -Id $connection.OwningProcess -Force
            Start-Sleep -Milliseconds 500
        }
    }
    $netstat = netstat -ano | Select-String ":$Port\s+.*LISTENING\s+(\d+)"
    foreach ($line in $netstat) {
        $pidText = $line.Matches[0].Groups[1].Value
        if ($pidText -match "^\d+$" -and (Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue)) {
            Write-Host "Port $Port is occupied by PID $pidText. Restarting it for DrivePilot Live."
            Stop-Process -Id ([int]$pidText) -Force
            Start-Sleep -Milliseconds 500
        }
    }
}

function Get-PortPid {
    param([int]$Port)
    $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($connection) { return [int]$connection.OwningProcess }
    $netstat = netstat -ano | Select-String ":$Port\s+.*LISTENING\s+(\d+)" | Select-Object -First 1
    if ($netstat) { return [int]$netstat.Matches[0].Groups[1].Value }
    return $null
}

function Start-DrivePilotProcess {
    param(
        [string]$Name,
        [string]$Arguments,
        [string]$OutLog,
        [string]$ErrLog
    )
    $powershellExe = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $OutLog) { Clear-Content -Path $OutLog }
    if (Test-Path -LiteralPath $ErrLog) { Clear-Content -Path $ErrLog }
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Starting $Name" | Set-Content -Path $OutLog -Encoding UTF8
    "Command: `"$powershellExe`" $Arguments" | Add-Content -Path $OutLog -Encoding UTF8

    $cmdExe = $env:ComSpec
    if ([string]::IsNullOrWhiteSpace($cmdExe)) { $cmdExe = "cmd.exe" }
    $cmdArgs = "/c `"`"$powershellExe`" $Arguments 1>>`"$OutLog`" 2>>`"$ErrLog`"`""
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $cmdExe
    $processInfo.Arguments = $cmdArgs
    $processInfo.WorkingDirectory = $projectRoot
    $processInfo.UseShellExecute = $true
    $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = [System.Diagnostics.Process]::Start($processInfo)
    if ($null -eq $process) {
        throw "Failed to start $Name."
    }
    Write-Host "$Name PID: $($process.Id)"
    return [int]$process.Id
}

$mapHealth = "http://127.0.0.1:$MapPort/index.html"
$receiverHealth = "http://127.0.0.1:$ReceiverPort/health"

$mapPid = $null
if (Test-HttpOk $mapHealth) {
    $mapPid = Get-PortPid -Port $MapPort
    Write-Host "Map server already responding on $MapPort PID=$mapPid"
}
else {
    Stop-PortListener -Port $MapPort
    $mapScript = Join-Path $scriptDir "map_server.ps1"
    $mapArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$mapScript`" -Port $MapPort -ListenAddress 0.0.0.0 -Root `"$mapDir`""
    $mapPid = Start-DrivePilotProcess -Name "Map server" -Arguments $mapArgs -OutLog (Join-Path $logsDir "map_server.out.log") -ErrLog (Join-Path $logsDir "map_server.err.log")
}

$receiverPid = $null
if (Test-HttpOk $receiverHealth) {
    $receiverPid = Get-PortPid -Port $ReceiverPort
    Write-Host "Notification receiver already responding on $ReceiverPort PID=$receiverPid"
}
else {
    Stop-PortListener -Port $ReceiverPort
    $receiverScript = Join-Path $scriptDir "line_notification_receiver.ps1"
    $configPath = Join-Path $scriptDir "notification_config.json"
    $receiverArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$receiverScript`" -Port $ReceiverPort -ListenAddress 0.0.0.0 -OutputDir `"$dataDir`" -ConfigPath `"$configPath`""
    $receiverPid = Start-DrivePilotProcess -Name "Notification receiver" -Arguments $receiverArgs -OutLog (Join-Path $logsDir "notification_receiver.out.log") -ErrLog (Join-Path $logsDir "notification_receiver.err.log")
}

Start-Sleep -Seconds 2

$lanIp = Get-LanIp

Write-Host ""
Write-Host "DrivePilot Live v1"
$mapOk = Test-HttpOk $mapHealth
$receiverOk = Test-HttpOk $receiverHealth
$detectedMapPid = Get-PortPid -Port $MapPort
$detectedReceiverPid = Get-PortPid -Port $ReceiverPort
if ($detectedMapPid) { $mapPid = $detectedMapPid }
if ($detectedReceiverPid) { $receiverPid = $detectedReceiverPid }
$status = [pscustomobject]@{
    started_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    map_port = $MapPort
    receiver_port = $ReceiverPort
    map_pid = $mapPid
    receiver_pid = $receiverPid
}
$status | ConvertTo-Json | Set-Content -Path $pidPath -Encoding UTF8
Write-Host "通知接收器狀態:    $(if ($receiverOk) { 'OK' } else { 'FAIL' })"
Write-Host "地圖服務狀態:      $(if ($mapOk) { 'OK' } else { 'FAIL' })"
if (-not $receiverOk) {
    Write-Host "[ERROR] Notification receiver failed health check. See: $(Join-Path $logsDir 'notification_receiver.err.log')"
    Write-Host "[ERROR] Runtime errors are written to: $(Join-Path $dataDir 'receiver_errors.jsonl')"
}
Write-Host "8788 PID:          $receiverPid"
Write-Host "8790 PID:          $mapPid"
Write-Host ""
Write-Host "地圖網址:          http://127.0.0.1:$MapPort/index.html"
Write-Host "桌面戰情室:        http://127.0.0.1:$MapPort/dashboard.html"
Write-Host "手機戰情室:        http://$lanIp`:$MapPort/mobile_dashboard.html"
Write-Host "通知接收器:        http://127.0.0.1:$ReceiverPort/notify"
Write-Host "通知接收器 LAN:    http://$lanIp`:$ReceiverPort/notify"
Write-Host "本機 health URL:   http://127.0.0.1:$ReceiverPort/health"
Write-Host "LAN health URL:    http://$lanIp`:$ReceiverPort/health"
Write-Host "LAN notify URL:    http://$lanIp`:$ReceiverPort/notify"
Write-Host "LAN dashboard URL: http://$lanIp`:$MapPort/dashboard.html"
Write-Host ""
Write-Host "模擬器若不能連 127.0.0.1，請用通知接收器 LAN 網址。"

if (-not $NoBrowser) {
    Start-Process "http://127.0.0.1:$MapPort/index.html"
}











