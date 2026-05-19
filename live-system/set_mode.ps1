param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$allowedModes = @("off", "quiet", "radar", "driving")
$normalizedMode = $Mode.Trim().ToLowerInvariant()

if (-not ($allowedModes -contains $normalizedMode)) {
    Write-Host "allowed modes: off, quiet, radar, driving"
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$configDir = Join-Path $projectRoot "config"
$modePath = Join-Path $configDir "drivepilot_mode.json"

if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir | Out-Null
}

Set-Content -Path $modePath -Value "{ `"mode`": `"$normalizedMode`" }" -Encoding UTF8
Write-Host "DrivePilot mode set to $normalizedMode"
