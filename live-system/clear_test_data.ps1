Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$dataDir = Join-Path $projectRoot "live-data"

$files = @(
    Join-Path $dataDir "test_notifications.jsonl",
    Join-Path $dataDir "test_ignored_notifications.jsonl"
)

foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file)) {
        New-Item -ItemType File -Path $file | Out-Null
    }
    Clear-Content -Path $file
    Write-Host "cleared $file"
}

