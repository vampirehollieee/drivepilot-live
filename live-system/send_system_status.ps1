param(
    [int]$MapPort = 8790,
    [int]$ReceiverPort = 8788
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$dataDir = Join-Path $projectRoot "live-data"
$notifier = Join-Path $scriptDir "discord_notifier.ps1"

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

$notificationsPath = Join-Path $dataDir "notifications.jsonl"
$placesPath = Join-Path $dataDir "places.csv"
$hotZonesPath = Join-Path $dataDir "hot_zones.json"
$lastLine = if (Test-Path -LiteralPath $notificationsPath) { Get-Content -Path $notificationsPath -Encoding UTF8 | Select-Object -Last 1 } else { "" }
$lastTime = "尚無資料"
if (-not [string]::IsNullOrWhiteSpace($lastLine)) {
    try { $lastTime = ($lastLine | ConvertFrom-Json).timestamp } catch {}
}

$message = @(
    "【DrivePilot 系統狀態】",
    "通知接收器 8788：$(if (Test-HttpOk ('http://127.0.0.1:' + $ReceiverPort + '/health')) { 'OK' } else { 'FAIL' })",
    "地圖服務 8790：$(if (Test-HttpOk ('http://127.0.0.1:' + $MapPort + '/index.html')) { 'OK' } else { 'FAIL' })",
    "notifications 筆數：$(Count-Lines $notificationsPath)",
    "places 筆數：$(Count-Lines $placesPath -SkipHeader)",
    "hot_zones 狀態：$(if (Test-Path -LiteralPath $hotZonesPath) { 'OK' } else { 'FAIL' })",
    "最後 LINE 通知時間：$lastTime"
) -join [Environment]::NewLine

powershell -NoProfile -ExecutionPolicy Bypass -File $notifier -Type system_status -Content $message

