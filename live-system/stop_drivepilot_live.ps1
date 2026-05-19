param(
    [int]$MapPort = 8790,
    [int]$ReceiverPort = 8788
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$pidPath = Join-Path $projectRoot "live-data\drivepilot_live_pids.json"
$stopped = New-Object System.Collections.Generic.List[string]

function Stop-ByPid {
    param([AllowNull()]$PidValue, [string]$Name)
    if ($null -ne $PidValue -and "$PidValue" -match "^\d+$" -and (Get-Process -Id ([int]$PidValue) -ErrorAction SilentlyContinue)) {
        Stop-Process -Id ([int]$PidValue) -Force
        $stopped.Add("$Name PID $PidValue")
    }
}

if (Test-Path -LiteralPath $pidPath) {
    $pids = Get-Content -Path $pidPath -Raw | ConvertFrom-Json
    Stop-ByPid -PidValue $pids.map_pid -Name "Map server"
    Stop-ByPid -PidValue $pids.receiver_pid -Name "Notification receiver"
}

foreach ($port in @($MapPort, $ReceiverPort)) {
    $connections = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($connection in $connections) {
        if ($connection.OwningProcess -and (Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $connection.OwningProcess -Force
            $stopped.Add("Port $port PID $($connection.OwningProcess)")
        }
    }
    $netstat = netstat -ano | Select-String ":$port\s+.*LISTENING\s+(\d+)"
    foreach ($line in $netstat) {
        $pidText = $line.Matches[0].Groups[1].Value
        if ($pidText -match "^\d+$" -and (Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue)) {
            Stop-Process -Id ([int]$pidText) -Force
            $stopped.Add("Port $port PID $pidText")
        }
    }
}

if ($stopped.Count -eq 0) {
    Write-Host "沒有找到正在執行的 DrivePilot Live 服務。"
}
else {
    Write-Host "已停止："
    $stopped | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
}
Write-Host "資料已保留，未刪除任何 live-data 檔案。"
if (Test-Path -LiteralPath $pidPath) {
    Remove-Item -LiteralPath $pidPath -Force
}







