param([switch]$Force)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$dataDir = Join-Path $projectRoot "live-data"
$hotZonesPath = Join-Path $dataDir "hot_zones.json"
$updateScript = Join-Path $scriptDir "update_hot_zones.ps1"
$notifier = Join-Path $scriptDir "discord_notifier.ps1"

if (Test-Path -LiteralPath $updateScript) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $updateScript -DataDir $dataDir | Out-Null
}
if (-not (Test-Path -LiteralPath $hotZonesPath)) {
    throw "hot_zones.json not found"
}

$hot = Get-Content -Path $hotZonesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$top = @($hot.zones | Where-Object { $_.area -ne "未知" } | Select-Object -First 3)
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("【DrivePilot 熱區摘要】")
$lines.Add("市場熱度：$($hot.market_heat)")
$lines.Add("前三熱區：")
if (-not $top.Count) {
    $lines.Add("目前熱區不足，仍需觀察")
}
else {
    for ($i = 0; $i -lt 3; $i++) {
        if ($i -lt $top.Count) {
            $zone = $top[$i]
            $lines.Add("$($i + 1). $($zone.area) score $($zone.score)，15分鐘 $($zone.count_15min) 筆，60分鐘 $($zone.count_60min) 筆")
        }
    }
}
$lines.Add("")
$lines.Add("建議：$($hot.advice)")
$message = $lines -join [Environment]::NewLine
$signature = (($top | ForEach-Object { "$($_.area):$($_.score)" }) -join "|") + "|heat:$($hot.market_heat)"

$arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $notifier, "-Type", "hot_zone_summary", "-Content", $message, "-Signature", $signature)
if ($Force) { $arguments += "-Force" }
powershell @arguments
