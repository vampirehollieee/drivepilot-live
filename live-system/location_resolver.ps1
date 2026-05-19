Set-StrictMode -Version Latest

$script:LocationResolverState = $null

function ConvertTo-ResolverCsvField {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    $Value = ($Value -replace "[\r\n]+", " ").Trim()
    return '"' + ($Value -replace '"', '""') + '"'
}

function Normalize-DrivePilotAddress {
    param([AllowNull()][string]$Address)
    if ($null -eq $Address) { return "" }
    $text = [string]$Address
    $text = $text.Replace([string][char]0x3000, " ")
    $text = [regex]::Replace($text, "\s+", " ")
    $punctuation = @(
        [char]0x002C, [char]0xFF0C, [char]0x3002, [char]0xFF1B, [char]0x003B,
        [char]0xFF1A, [char]0x003A, [char]0xFF0F, [char]0x002F, [char]0x007C,
        [char]0xFF5C, [char]0x0028, [char]0x0029, [char]0xFF08, [char]0xFF09,
        [char]0x005B, [char]0x005D, [char]0x3010, [char]0x3011
    )
    foreach ($ch in $punctuation) {
        $text = $text.Replace([string]$ch, "")
    }
    return $text.Trim()
}

function Get-DrivePilotMatchKey {
    param([AllowNull()][string]$Address)
    return ((Normalize-DrivePilotAddress -Address $Address) -replace "\s+", "")
}

function Ensure-ResolverCsv {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Header
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        [System.IO.File]::WriteAllText($Path, $Header + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
        return
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -eq 0) {
        [System.IO.File]::WriteAllText($Path, $Header + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    }
}

function Write-ResolverCsvAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Rows
    )
    $temp = "$Path.tmp"
    @($Rows) | Export-Csv -Path $temp -NoTypeInformation -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Add-ResolverIndexKey {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)]$Row
    )
    $matchKey = Get-DrivePilotMatchKey -Address $Key
    if ($matchKey.Length -gt 0 -and -not $Index.ContainsKey($matchKey)) {
        $Index[$matchKey] = $Row
    }
}

function Add-ResolverRow {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)]$Rows,
        [Parameter(Mandatory = $true)][string]$Address,
        [AllowNull()][string]$Note,
        [AllowNull()][string]$Aliases,
        [Parameter(Mandatory = $true)][double]$Lat,
        [Parameter(Mandatory = $true)][double]$Lng,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Confidence
    )
    if ($Lat -lt -90 -or $Lat -gt 90 -or $Lng -lt -180 -or $Lng -gt 180) { return }
    $row = [pscustomobject]@{
        raw_address = $Address
        normalized_address = Normalize-DrivePilotAddress -Address $Address
        match_key = Get-DrivePilotMatchKey -Address $Address
        lat = $Lat
        lng = $Lng
        source = $Source
        confidence = $Confidence
        note = [string]$Note
    }
    $Rows.Add($row) | Out-Null
    foreach ($key in @($Address, $Note, $Aliases)) {
        if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
        Add-ResolverIndexKey -Index $Index -Key ([string]$key) -Row $row
        $splitText = [string]$key
        foreach ($ch in @([char]0x002C, [char]0xFF0C, [char]0xFF1B, [char]0x003B, [char]0x007C, [char]0xFF5C)) {
            $splitText = $splitText.Replace([string]$ch, " ")
        }
        foreach ($part in ($splitText -split "\s+")) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            Add-ResolverIndexKey -Index $Index -Key $part -Row $row
        }
    }
}

function Initialize-LocationResolver {
    param([string]$DataDir = "")
    $scriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $PSCommandPath } else { $PSScriptRoot }
    $projectRoot = Split-Path -Parent $scriptDir
    if ([string]::IsNullOrWhiteSpace($DataDir)) {
        $DataDir = Join-Path $projectRoot "live-data"
    }
    $resolvedDataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DataDir)
    New-Item -ItemType Directory -Force -Path $resolvedDataDir | Out-Null

    $cachePath = Join-Path $resolvedDataDir "address_geocode_cache.csv"
    $unresolvedPath = Join-Path $resolvedDataDir "unresolved_addresses.csv"
    $resolvedPath = Join-Path $resolvedDataDir "map_resolved_points.csv"
    $mapPointsPath = Join-Path $resolvedDataDir "map_points.csv"

    Ensure-ResolverCsv -Path $cachePath -Header "raw_address,normalized_address,match_key,lat,lng,source,confidence,note,updated_at"
    Ensure-ResolverCsv -Path $unresolvedPath -Header "raw_address,normalized_address,match_key,first_seen,last_seen,count,status,sample_text"
    Ensure-ResolverCsv -Path $resolvedPath -Header "time,group,address,normalized_address,lat,lng,source,confidence,kind,text_summary"

    $mapIndex = @{}
    $mapRows = New-Object System.Collections.ArrayList
    $cacheIndex = @{}
    $cacheRows = New-Object System.Collections.ArrayList
    $unresolvedIndex = @{}
    $resolvedEventKeys = @{}

    if (Test-Path -LiteralPath $mapPointsPath) {
        foreach ($row in @(Import-Csv -Path $mapPointsPath -Encoding UTF8)) {
            try {
                $lat = [double]([string]$row.lat)
                $lng = [double]([string]$row.lng)
                $aliases = if ($row.PSObject.Properties.Name -contains "aliases") { [string]$row.aliases } else { "" }
                Add-ResolverRow -Index $mapIndex -Rows $mapRows -Address ([string]$row.address) -Note ([string]$row.note) -Aliases $aliases -Lat $lat -Lng $lng -Source "map_points" -Confidence "high"
            }
            catch {}
        }
    }

    foreach ($row in @(Import-Csv -Path $cachePath -Encoding UTF8)) {
        try {
            $lat = [double]([string]$row.lat)
            $lng = [double]([string]$row.lng)
            $confidence = if ([string]::IsNullOrWhiteSpace([string]$row.confidence)) { "medium" } else { [string]$row.confidence }
            $address = if ([string]::IsNullOrWhiteSpace([string]$row.normalized_address)) { [string]$row.raw_address } else { [string]$row.normalized_address }
            Add-ResolverRow -Index $cacheIndex -Rows $cacheRows -Address $address -Note ([string]$row.note) -Aliases ([string]$row.match_key) -Lat $lat -Lng $lng -Source "address_geocode_cache" -Confidence $confidence
        }
        catch {}
    }

    foreach ($row in @(Import-Csv -Path $unresolvedPath -Encoding UTF8)) {
        $key = [string]$row.match_key
        if (-not [string]::IsNullOrWhiteSpace($key)) { $unresolvedIndex[$key] = $row }
    }
    foreach ($row in @(Import-Csv -Path $resolvedPath -Encoding UTF8)) {
        $key = "$($row.time)|$($row.group)|$($row.normalized_address)"
        if (-not [string]::IsNullOrWhiteSpace($key)) { $resolvedEventKeys[$key] = $true }
    }

    $script:LocationResolverState = [pscustomobject]@{
        DataDir = $resolvedDataDir
        MapPointsPath = $mapPointsPath
        CachePath = $cachePath
        UnresolvedPath = $unresolvedPath
        ResolvedPath = $resolvedPath
        MapIndex = $mapIndex
        MapRows = $mapRows
        CacheIndex = $cacheIndex
        CacheRows = $cacheRows
        UnresolvedIndex = $unresolvedIndex
        ResolvedEventKeys = $resolvedEventKeys
    }
    return $script:LocationResolverState
}

function Find-ResolverMatch {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)]$Rows,
        [Parameter(Mandatory = $true)][string]$Address,
        [AllowNull()][string]$Text
    )
    $candidates = @($Address, $Text) | ForEach-Object { Get-DrivePilotMatchKey -Address $_ } | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if ($Index.ContainsKey($candidate)) { return $Index[$candidate] }
    }
    foreach ($row in @($Rows)) {
        foreach ($candidate in $candidates) {
            foreach ($key in @($row.match_key, (Get-DrivePilotMatchKey -Address $row.note), (Get-DrivePilotMatchKey -Address $row.raw_address))) {
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                if ($candidate.Contains($key) -or $key.Contains($candidate)) { return $row }
            }
        }
    }
    return $null
}

function Update-UnresolvedAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [AllowNull()][string]$Text
    )
    $state = $script:LocationResolverState
    if ($null -eq $state) { return }
    $normalized = Normalize-DrivePilotAddress -Address $Address
    $key = Get-DrivePilotMatchKey -Address $Address
    if ([string]::IsNullOrWhiteSpace($key)) { return }

    $rows = New-Object System.Collections.ArrayList
    $found = $false
    foreach ($row in @(Import-Csv -Path $state.UnresolvedPath -Encoding UTF8)) {
        if ([string]$row.match_key -eq $key) {
            $count = 1
            [int]::TryParse([string]$row.count, [ref]$count) | Out-Null
            $row.last_seen = $Timestamp
            $row.count = [string]($count + 1)
            $found = $true
            $state.UnresolvedIndex[$key] = $row
        }
        $rows.Add($row) | Out-Null
    }
    if (-not $found) {
        $sample = [string]$Text
        if ($sample.Length -gt 120) { $sample = $sample.Substring(0, 120) }
        $row = [pscustomobject]@{
            raw_address = $Address
            normalized_address = $normalized
            match_key = $key
            first_seen = $Timestamp
            last_seen = $Timestamp
            count = "1"
            status = "unresolved"
            sample_text = $sample
        }
        $rows.Add($row) | Out-Null
        $state.UnresolvedIndex[$key] = $row
    }
    Write-ResolverCsvAtomic -Path $state.UnresolvedPath -Rows $rows
}

function Add-ResolvedMapPoint {
    param(
        [Parameter(Mandatory = $true)]$Match,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $state = $script:LocationResolverState
    if ($null -eq $state) { return }
    $normalized = Normalize-DrivePilotAddress -Address $Address
    $eventKey = "$Timestamp|$Group|$normalized"
    if ($state.ResolvedEventKeys.ContainsKey($eventKey)) { return }
    $summary = [string]$Text
    if ($summary.Length -gt 120) { $summary = $summary.Substring(0, 120) }
    $line = @(
        ConvertTo-ResolverCsvField $Timestamp
        ConvertTo-ResolverCsvField $Group
        ConvertTo-ResolverCsvField $Address
        ConvertTo-ResolverCsvField $normalized
        ConvertTo-ResolverCsvField ([string]$Match.lat)
        ConvertTo-ResolverCsvField ([string]$Match.lng)
        ConvertTo-ResolverCsvField ([string]$Match.source)
        ConvertTo-ResolverCsvField ([string]$Match.confidence)
        ConvertTo-ResolverCsvField $Kind
        ConvertTo-ResolverCsvField $summary
    ) -join ","
    [System.IO.File]::AppendAllText($state.ResolvedPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    $state.ResolvedEventKeys[$eventKey] = $true
}

function Resolve-DrivePilotLocation {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Text
    )
    try {
        if ($null -eq $script:LocationResolverState) { Initialize-LocationResolver | Out-Null }
        $match = Find-ResolverMatch -Index $script:LocationResolverState.MapIndex -Rows $script:LocationResolverState.MapRows -Address $Address -Text $Text
        if ($null -eq $match) {
            $cacheMatch = Find-ResolverMatch -Index $script:LocationResolverState.CacheIndex -Rows $script:LocationResolverState.CacheRows -Address $Address -Text $Text
            if ($null -ne $cacheMatch) { $match = $cacheMatch }
        }
        if ($null -ne $match) {
            Add-ResolvedMapPoint -Match $match -Timestamp $Timestamp -Group $Group -Address $Address -Kind $Kind -Text $Text
            return [pscustomobject]@{ resolved = $true; source = [string]$match.source; lat = $match.lat; lng = $match.lng }
        }
        Update-UnresolvedAddress -Address $Address -Timestamp $Timestamp -Text $Text
        return [pscustomobject]@{ resolved = $false; source = "unresolved" }
    }
    catch {
        Write-Host "[DrivePilot Resolver] failed: $($_.Exception.Message)"
        return [pscustomobject]@{ resolved = $false; source = "error"; error = $_.Exception.Message }
    }
}
