param(
    [int]$Port = 8788,
    [string]$ListenAddress = "0.0.0.0",
    [string]$OutputDir = ".\line-notify-output",
    [string]$ConfigPath = "",
    [string]$DefaultCity = "高雄市"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $script:Utf8NoBom
$OutputEncoding = $script:Utf8NoBom
$script:ReceiverScriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $PSCommandPath } else { $PSScriptRoot }
$script:LocationResolverAvailable = $false
$locationResolverPath = Join-Path $script:ReceiverScriptDir "location_resolver.ps1"
if (Test-Path -LiteralPath $locationResolverPath) {
    try {
        . $locationResolverPath
        $script:LocationResolverAvailable = $true
    }
    catch {
        Write-Host "[DrivePilot Resolver] load failed: $($_.Exception.Message)"
    }
}

function ConvertTo-CsvField {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    $Value = ($Value -replace "[\r\n]+", " ").Trim()
    return '"' + ($Value -replace '"', '""') + '"'
}

function Add-Utf8Line {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Line
    )
    [System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine, $script:Utf8NoBom)
}

function Get-BodyEncoding {
    param([AllowNull()][string]$ContentType)

    if (-not [string]::IsNullOrWhiteSpace($ContentType) -and $ContentType -match "charset\s*=\s*([^;\s]+)") {
        $charset = $matches[1].Trim('"')
        try {
            return [System.Text.Encoding]::GetEncoding($charset)
        }
        catch {
            Write-Host "[DrivePilot Encoding] unsupported charset=$charset fallback=utf-8"
        }
    }

    return $script:Utf8NoBom
}

function Test-MojibakeText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match "�|嚚|||Ã|Â|æ|å|ç|è")
}

function Test-JsonLikeText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $trimmed = $Text.Trim()
    if (-not ($trimmed.StartsWith("{") -or $trimmed.StartsWith("["))) { return $false }
    try {
        $trimmed | ConvertFrom-Json | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function ConvertFrom-RequestBodyBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [AllowNull()][string]$ContentType
    )

    if ($Bytes.Length -eq 0) { return "" }

    $utf8Text = $script:Utf8NoBom.GetString($Bytes)
    $declaredEncoding = Get-BodyEncoding -ContentType $ContentType
    $declaredName = $declaredEncoding.WebName.ToLowerInvariant()
    if ($declaredName -eq "utf-8" -or $declaredName -eq "utf-8-sig") {
        return $utf8Text
    }

    $declaredText = $declaredEncoding.GetString($Bytes)
    if ((Test-MojibakeText -Text $declaredText) -and -not (Test-MojibakeText -Text $utf8Text)) {
        Write-Host "[DrivePilot Encoding] corrected mojibake by using utf-8 instead of charset=$declaredName"
        return $utf8Text
    }

    if (($ContentType -match "json" -or (Test-JsonLikeText -Text $utf8Text)) -and (Test-JsonLikeText -Text $utf8Text)) {
        return $utf8Text
    }

    return $declaredText
}

function Read-Config {
    param([string]$Path)

    $default = [pscustomobject]@{
        line_filters = [pscustomobject]@{
            allowed_packages = @("jp.naver.line.android")
            allowed_groups = @()
            dispatcher_contacts = @()
            ignore_keywords = @("貼圖", "相簿", "收回訊息", "加入群組")
        }
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $default
    }

    try {
        return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $default
    }
}

function Get-JsonBody {
    param([AllowNull()][string]$Body)

    $body = [string]$Body
    if ([string]::IsNullOrWhiteSpace($body)) {
        return [pscustomobject]@{}
    }

    try {
        return $body | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            text = $body
        }
    }
}

function Normalize-Text {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return "" }
    $Text = $Text -replace "０", "0" -replace "１", "1" -replace "２", "2" -replace "３", "3" -replace "４", "4" -replace "５", "5" -replace "６", "6" -replace "７", "7" -replace "８", "8" -replace "９", "9"
    $Text = $Text -replace "𝟬", "0" -replace "𝟭", "1" -replace "𝟮", "2" -replace "𝟯", "3" -replace "𝟰", "4" -replace "𝟱", "5" -replace "𝟲", "6" -replace "𝟳", "7" -replace "𝟴", "8" -replace "𝟵", "9"
    return (($Text -replace "\u3000", " ") -replace "\s+", " ").Trim()
}

function Get-NotificationText {
    param($Payload)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in @("title", "app", "group", "conversation", "text", "message", "bigText", "summary", "ticker")) {
        if ($Payload.PSObject.Properties.Name -contains $name) {
            $value = [string]$Payload.$name
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $parts.Add($value)
            }
        }
    }
    return (($parts | Select-Object -Unique) -join "`n").Trim()
}

function Get-GroupName {
    param($Payload)

    foreach ($name in @("group", "conversation", "title")) {
        if ($Payload.PSObject.Properties.Name -contains $name) {
            $value = Normalize-Text ([string]$Payload.$name)
            if ($value.Length -gt 0) { return $value }
        }
    }
    return "LINE 通知"
}

function Test-ShouldProcessNotification {
    param(
        $Payload,
        [string]$Group,
        [string]$Text,
        $Config
    )

    $filters = $Config.line_filters
    $package = ""
    if ($Payload.PSObject.Properties.Name -contains "package") {
        $package = Normalize-Text ([string]$Payload.package)
    }

    if ($package.Length -gt 0) {
        $allowedPackages = @($filters.allowed_packages)
        if ($allowedPackages.Count -gt 0 -and -not ($allowedPackages -contains $package)) {
            return [pscustomobject]@{ process = $false; reason = "non_line_package"; package = $package }
        }
    }

    $allowedGroups = @($filters.allowed_groups)
    if ($allowedGroups.Count -gt 0) {
        $matched = $false
        foreach ($keyword in $allowedGroups) {
            if ($Group -like "*$keyword*") {
                $matched = $true
                break
            }
        }
        if (-not $matched) {
            return [pscustomobject]@{ process = $false; reason = "group_not_allowed"; package = $package }
        }
    }

    foreach ($keyword in @($filters.ignore_keywords)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$keyword) -and $Text -like "*$keyword*") {
            return [pscustomobject]@{ process = $false; reason = "ignore_keyword:$keyword"; package = $package }
        }
    }

    return [pscustomobject]@{ process = $true; reason = "accepted"; package = $package }
}

function Get-PersonalAlertText {
    param($Payload)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in @("message", "text", "body", "raw_text", "content")) {
        if ($Payload.PSObject.Properties.Name -contains $name) {
            $value = Normalize-Text ([string]$Payload.$name)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $parts.Add($value)
            }
        }
    }

    return (($parts | Select-Object -Unique) -join "`n")
}

function Test-PersonalAlert {
    param(
        $Payload,
        [string]$Group,
        [string]$Text,
        $Config
    )

    $messageText = Get-PersonalAlertText -Payload $Payload
    $rules = @(
        [pscustomobject]@{ reason = "@東尼工作機"; keyword = "@東尼工作機"; pattern = "(?:@|＠)\s*東尼工作機" },
        [pscustomobject]@{ reason = "東尼工作機"; keyword = "東尼工作機"; pattern = "東尼工作機" },
        [pscustomobject]@{ reason = "代駕"; keyword = "代駕"; pattern = "代駕" }
    )

    foreach ($rule in $rules) {
        if ([regex]::IsMatch($messageText, [string]$rule.pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            return [pscustomobject]@{
                is_personal_alert = $true
                reason = [string]$rule.reason
                keyword = [string]$rule.keyword
                source = "message"
            }
        }
    }

    return [pscustomobject]@{
        is_personal_alert = $false
        reason = ""
        keyword = ""
        source = "message_only"
    }
}

function Get-AddressCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$City
    )

    $searchText = Normalize-Text $Text
    $searchText = $searchText -replace "(?:通知時間|時間)[:：]\s*(?:[01]?\d|2[0-3])[:：]?[0-5]\d", " "
    $searchText = $searchText -replace "\b(?:[01]?\d|2[0-3])[:：][0-5]\d\b", " "
    $searchText = $searchText -replace "\b(?:[01]?\d|2[0-3])[.．][0-5]\d\b", " "
    $searchText = $searchText -replace "(?:低消|低銷)\s*\d+|\d+\s*/\s*\d+\s*/\s*\d+", " "
    $compact = $searchText -replace "\s+", ""
    $patterns = @(
        "(?:高雄市)?[\p{IsCJKUnifiedIdeographs}]{1,4}區[\p{IsCJKUnifiedIdeographs}0-9一二三四五六七八九十之\-]+(?:路|街|大道|巷|弄)[\p{IsCJKUnifiedIdeographs}0-9一二三四五六七八九十之\-]*(?:號)?",
        "[\p{IsCJKUnifiedIdeographs}0-9一二三四五六七八九十之\-]{2,}(?:路|街|大道|巷|弄)[\p{IsCJKUnifiedIdeographs}0-9一二三四五六七八九十之\-]*(?:號)?",
        "[\p{IsCJKUnifiedIdeographs}0-9一二三四五六七八九十之\-]{2,}(?:交流道|休息站|服務區|停車場|加油站|景觀台|咖啡|餐廳|公園|漁港)"
    )

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($compact, $pattern)) {
            $address = $match.Value
            if ($address -match "高雄市") {
                $address = ($address -replace "^.*?(高雄市)", '$1')
            }
            $address = $address -replace "^起點[:：]?", ""
            $address = $address -replace "^終點[:：]?", ""
            $address = $address -replace "^上車[:：]?", ""
            $address = $address -replace "^下車[:：]?", ""
            $address = $address -replace "^地址[:：]?", ""
            $address = $address -replace "^上[:：]?", ""
            $address = $address -replace "^下[:：]?", ""
            $address = $address -replace "(-|－)路", "一路"
            if ($address -match "號") {
                $address = ($address -replace "^(.*?號).*$", '$1')
            }
            $address = Clean-AddressCandidate -Address $address -City $City

            if ($address.Length -ge 3 -and -not ($address -match "低消|百回|外群|內群")) {
                $address = Complete-KaohsiungAddress -Address $address -City $City
                $found.Add($address)
            }
        }
    }
    return $found | Select-Object -Unique
}

function Clean-AddressCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$City
    )

    $cleaned = Normalize-Text $Address
    $cleaned = $cleaned -replace "[,，。；;]+$", ""
    $cleaned = $cleaned -replace "^(?:時間|通知時間)[:：]?\s*(?:[01]?\d|2[0-3])[:：]?[0-5]\d", ""
    $cleaned = $cleaned -replace "$City\s*(?:[01]?\d|2[0-3]|[0-5]\d)(?=[\p{IsCJKUnifiedIdeographs}]{1,4}區)", $City
    $cleaned = $cleaned -replace "^(?:[01]?\d|2[0-3])[:：]?[0-5]\d(?=[\p{IsCJKUnifiedIdeographs}])", ""
    $cleaned = $cleaned -replace "^[0-5]\d(?=[\p{IsCJKUnifiedIdeographs}0-9一二三四五六七八九十之\-]+(?:路|街|大道|巷|弄))", ""
    $cleaned = $cleaned -replace "^(?:低消|低銷)\d+", ""
    $cleaned = $cleaned -replace "^\d+/\d+/\d+", ""
    return $cleaned.Trim()
}

function Complete-KaohsiungAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$City
    )

    $address = Clean-AddressCandidate -Address $Address -City $City
    if (($address -match "區") -and -not $address.StartsWith($City)) {
        return "$City$address"
    }
    if ($address.StartsWith($City)) {
        return $address
    }

    $roadDistrictMap = @{
        "明誠一路" = "鼓山區"
        "大平路" = "小港區"
    }
    foreach ($road in $roadDistrictMap.Keys) {
        if ($address -like "$road*") {
            return "$City$($roadDistrictMap[$road])$address"
        }
    }
    return $address
}

function Get-LabeledAddressCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$City
    )

    $normalized = Normalize-Text $Text
    $segments = New-Object System.Collections.Generic.List[string]
    $startLabels = "(?:起點|上車|地址|上)"
    $stopLabels = "(?:起點|上車|地址|上|終點|下車|下|備註|時間|低消|低銷|接單|回|外詳|備)"
    foreach ($match in [regex]::Matches($normalized, "$startLabels[:：]\s*(.+?)(?=\s*$stopLabels(?:[:：]|\s|$)|$)")) {
        $segments.Add($match.Groups[1].Value)
    }

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $segments) {
        foreach ($address in @(Get-AddressCandidates -Text $segment -City $City)) {
            $found.Add($address)
        }
    }
    return $found | Select-Object -Unique
}

function Get-PlaceAliasCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)]$Aliases
    )

    $normalized = Normalize-Text $Text
    $found = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($entry in @($Aliases)) {
        foreach ($alias in @($entry.aliases)) {
            $aliasText = Normalize-Text ([string]$alias)
            if ($aliasText.Length -eq 0) { continue }
            if ($normalized -like "*$aliasText*") {
                $address = [string]$entry.address
                $key = "$aliasText|$address"
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $found.Add([pscustomobject]@{
                    address = $address
                    kind = if ($entry.PSObject.Properties.Name -contains "kind") { [string]$entry.kind } else { "place_alias" }
                    confidence = if ($entry.PSObject.Properties.Name -contains "confidence") { [string]$entry.confidence } else { "high" }
                    note = "地標解析：$aliasText → $address"
                    alias = $aliasText
                })
            }
        }
    }
    return $found
}

function Test-DescriptionText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $normalized = Normalize-Text $Text
    return ($normalized -match "旁邊|巷子裡|門口|街口|對面|附近|轉角|進去|7-11|超商")
}

function Test-DriverReply {
    param([Parameter(Mandatory = $true)][string]$Text)

    $normalized = Normalize-Text $Text
    if ($normalized.Length -gt 40) { return $false }
    $hasPlate = $normalized -match "(^|[^0-9A-Za-z])(?:[A-Z]{1,3}-?\d{3,4}|\d{3,4})([^0-9A-Za-z]|$)"
    $hasEta = $normalized -match "(?:約\s*)?\d{1,2}\s*(?:分|分鐘)"
    $hasColor = $normalized -match "(白車|黑車|灰車|銀車|紅車|藍車|黃車|[^一-龥](白|黑|灰|銀|紅|藍|黃)([^一-龥]|$))"
    $looksDelimited = $normalized -match "[/／,，\s]"
    return ($hasPlate -and $hasEta -and $hasColor -and $looksDelimited)
}

function New-ParserDiagnostic {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Package = "",
        [object[]]$PlaceCandidates = @(),
        [string]$Kind = "",
        [string]$IgnoredReason = "",
        [bool]$IsDriverReply = $false
    )

    $addresses = @($PlaceCandidates | ForEach-Object { [string]$_.address } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $confidences = @($PlaceCandidates | ForEach-Object { [string]$_.confidence } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $hasDescription = $false
    foreach ($place in @($PlaceCandidates)) {
        if ([string]$place.kind -eq "description") {
            $hasDescription = $true
            break
        }
    }

    $parserResult = "no_address"
    if (-not [string]::IsNullOrWhiteSpace($IgnoredReason)) {
        $parserResult = "ignored"
    }
    elseif ($IsDriverReply -or $Kind -eq "driver_reply") {
        $parserResult = "driver_reply"
    }
    elseif ($hasDescription) {
        $parserResult = "description"
    }
    elseif ($addresses.Count -gt 0) {
        $parserResult = "parsed"
    }

    return [pscustomobject]@{
        received_at = $Timestamp
        title = $Group
        package = $Package
        text = $Text
        text_length = ([string]$Text).Length
        matched_addresses = $addresses
        address_count = $addresses.Count
        kind = $Kind
        confidence = ($confidences -join "/")
        ignored_reason = $IgnoredReason
        parser_result = $parserResult
    }
}

function Get-PlaceCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$City,
        [Parameter(Mandatory = $true)]$Aliases,
        [string]$DefaultKind = "place",
        [string]$DefaultNote = ""
    )

    $labeledAddresses = @(Get-LabeledAddressCandidates -Text $Text -City $City)
    $addressesToUse = $labeledAddresses
    $hasHighLabeledAddress = $false
    foreach ($address in $labeledAddresses) {
        if ((Get-AddressConfidence -Address $address) -eq "high") {
            $hasHighLabeledAddress = $true
            break
        }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    if (-not $hasHighLabeledAddress) {
        foreach ($aliasCandidate in @(Get-PlaceAliasCandidates -Text $Text -Aliases $Aliases)) {
            $candidates.Add($aliasCandidate)
        }
    }

    if ($addressesToUse.Count -eq 0) {
        $addressesToUse = @(Get-AddressCandidates -Text $Text -City $City)
    }

    foreach ($address in $addressesToUse) {
        $confidence = Get-AddressConfidence -Address $address
        if ((Test-DescriptionText -Text $address) -and -not ($address -match "高雄市[\p{IsCJKUnifiedIdeographs}]{1,4}區.*(?:路|街|巷).*號")) {
            $confidence = "low"
        }
        $candidates.Add([pscustomobject]@{
            address = $address
            kind = $DefaultKind
            confidence = $confidence
            note = $DefaultNote
            alias = ""
        })
    }

    if (-not $hasHighLabeledAddress -and $candidates.Count -eq 0 -and (Test-DescriptionText -Text $Text)) {
        $description = (Normalize-Text $Text)
        if ($description.Length -gt 90) { $description = $description.Substring(0, 90) }
        $candidates.Add([pscustomobject]@{
            address = $description
            kind = "description"
            confidence = "low"
            note = "待確認地點：描述型文字"
            alias = ""
        })
    }

    $unique = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($candidate in $candidates) {
        $key = "$($candidate.kind)|$($candidate.address)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $unique.Add($candidate)
    }
    return $unique
}

function Get-TimeCandidates {
    param([Parameter(Mandatory = $true)][string]$Text)

    $times = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($Text, "\b([01]?\d|2[0-3])[:：][0-5]\d\b")) {
        $times.Add(($match.Value -replace "：", ":"))
    }
    foreach ($match in [regex]::Matches($Text, "\b([01]?\d|2[0-3])[.．]([0-5]\d)\b")) {
        $times.Add($match.Groups[1].Value + ":" + $match.Groups[2].Value)
    }
    foreach ($match in [regex]::Matches(($Text -replace "\s+", ""), "(^|[^0-9])([01]\d|2[0-3])([0-5]\d)([^0-9]|$)")) {
        $raw = $match.Groups[2].Value + $match.Groups[3].Value
        $times.Add(($raw.Substring(0, $raw.Length - 2)) + ":" + $raw.Substring($raw.Length - 2))
    }
    return $times | Select-Object -Unique
}

function Get-Note {
    param([Parameter(Mandatory = $true)][string]$Text)
    $normalized = Normalize-Text $Text
    $match = [regex]::Match($normalized, "備註[:：]\s*(.+)$")
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return ""
}

function Get-PriceNote {
    param([Parameter(Mandatory = $true)][string]$Text)
    $normalized = Normalize-Text $Text
    $matches = [regex]::Matches($normalized, "(?:低消|低銷)\s*\d+|(?:\d+\s*[:：]\s*\d+\s*[-－]\s*\d+)|(?:\d+\s*/\s*\d+\s*/\s*\d+)")
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($match in $matches) {
        $items.Add(($match.Value -replace "\s+", ""))
    }
    return (($items | Select-Object -Unique) -join " / ")
}

function Get-Kind {
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($Text -match "終點|下車|下[:：]") { return "end" }
    if ($Text -match "起點|上車|集合|出發|上[:：]") { return "start" }
    return "place"
}

function Get-AddressConfidence {
    param([Parameter(Mandatory = $true)][string]$Address)

    if ($Address -match "高雄市[\p{IsCJKUnifiedIdeographs}]{1,4}區.*(?:路|街|巷).*號") {
        return "high"
    }
    if ($Address -match "[\p{IsCJKUnifiedIdeographs}]{1,4}區.*(?:路|街|巷)") {
        return "medium"
    }
    return "low"
}

function Ensure-PlacesFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $header = "timestamp,group,kind,address,confidence,notification_time,note,price_note,text"
    if (-not (Test-Path $Path)) {
        [System.IO.File]::WriteAllText($Path, $header + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
        return
    }

    $firstLine = Get-Content -Path $Path -Encoding UTF8 -TotalCount 1
    if ($firstLine -eq $header) { return }

    $rows = @()
    try {
        $rows = @(Import-Csv -Path $Path -Encoding UTF8)
    }
    catch {
        $rows = @()
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($header)
    foreach ($row in $rows) {
        $address = [string]$row.address
        $confidence = if ($row.PSObject.Properties.Name -contains "confidence" -and -not [string]::IsNullOrWhiteSpace($row.confidence)) {
            $row.confidence
        }
        else {
            Get-AddressConfidence -Address $address
        }
        $notificationTime = if ($row.PSObject.Properties.Name -contains "notification_time") { [string]$row.notification_time } else { [string]$row.times }
        $note = if ($row.PSObject.Properties.Name -contains "note") { [string]$row.note } else { Get-Note -Text ([string]$row.text) }
        $priceNote = if ($row.PSObject.Properties.Name -contains "price_note") { [string]$row.price_note } else { Get-PriceNote -Text ([string]$row.text) }
        $fields = @($row.timestamp, $row.group, $row.kind, $address, $confidence, $notificationTime, $note, $priceNote, $row.text) | ForEach-Object { ConvertTo-CsvField ([string]$_) }
        $lines.Add(($fields -join ","))
    }
    [System.IO.File]::WriteAllLines($Path, $lines, [System.Text.Encoding]::UTF8)
}

function Test-DuplicatePlace {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Address
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $currentTime = [datetime]::MinValue
    if (-not [datetime]::TryParse($Timestamp, [ref]$currentTime)) { return $false }

    try {
        $rows = @(Import-Csv -Path $Path -Encoding UTF8)
        foreach ($row in $rows) {
            if ([string]$row.group -ne $Group -or [string]$row.address -ne $Address) { continue }
            $rowTime = [datetime]::MinValue
            if ([datetime]::TryParse([string]$row.timestamp, [ref]$rowTime)) {
                if ([math]::Abs(($currentTime - $rowTime).TotalMinutes) -le 10) {
                    return $true
                }
            }
        }
    }
    catch {
        return $false
    }
    return $false
}

function Update-HotZones {
    param([Parameter(Mandatory = $true)][string]$DataDir)

    $scriptPath = Join-Path $script:ReceiverScriptDir "update_hot_zones.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath)) { return }
    try {
        powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -DataDir $DataDir | Out-Null
    }
    catch {
        Write-Host "hot zone update failed: $($_.Exception.Message)"
    }
}

function Send-HighConfidenceDiscord {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$SystemTime,
        [string]$NotificationTime = "",
        [string]$Note = "",
        [string]$PriceNote = "",
        [string]$Kind = "",
        [string]$Confidence = "high"
    )

    $scriptPath = Join-Path $script:ReceiverScriptDir "discord_notifier.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath)) { return }
    try {
        $arguments = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
            "-Type", "high_confidence_address",
            "-Address", $Address,
            "-Group", $Group,
            "-SystemTime", $SystemTime
        )
        if (-not [string]::IsNullOrWhiteSpace($Kind)) { $arguments += @("-Kind", $Kind) }
        if (-not [string]::IsNullOrWhiteSpace($Confidence)) { $arguments += @("-Confidence", $Confidence) }
        if (-not [string]::IsNullOrWhiteSpace($NotificationTime)) { $arguments += @("-NotificationTime", $NotificationTime) }
        if (-not [string]::IsNullOrWhiteSpace($Note)) { $arguments += @("-Note", $Note) }
        if (-not [string]::IsNullOrWhiteSpace($PriceNote)) { $arguments += @("-PriceNote", $PriceNote) }
        $discordOutput = powershell @arguments 2>&1
        foreach ($line in @($discordOutput)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                Write-Host $line
            }
        }
    }
    catch {
        Write-Host "discord locatable signal push failed: $($_.Exception.Message)"
    }
}

function Send-PersonalAlertDiscord {
    param(
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$SystemTime,
        [string]$Keyword = "",
        [string]$Reason = "",
        [string]$AddressSummary = "",
        [string]$NotificationTime = ""
    )

    $scriptPath = Join-Path $script:ReceiverScriptDir "discord_notifier.ps1"
    $summary = Normalize-Text $Text
    if ($summary.Length -gt 240) { $summary = $summary.Substring(0, 240) + "..." }
    $message = @(
        "【個人提醒】",
        $(if ($Reason) { "觸發原因：$Reason" } else { "" }),
        "來源：$Group",
        $(if ($Keyword) { "命中內容：$Keyword" } else { "" }),
        $(if ($NotificationTime) { "通知時間：$NotificationTime" } else { "" }),
        "系統時間：$SystemTime",
        $(if ($AddressSummary) { "地址摘要：$AddressSummary" } else { "" }),
        "摘要：$summary"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $content = $message -join [Environment]::NewLine

    try {
        $arguments = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
            "-Type", "dispatcher_alert",
            "-Content", $content,
            "-Group", $Group,
            "-Kind", "personal_alert"
        )
        $discordOutput = powershell @arguments 2>&1
        foreach ($line in @($discordOutput)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                Write-Host $line
            }
        }
    }
    catch {
        Write-Host "discord personal alert push failed: $($_.Exception.Message)"
    }
}

function Read-HttpRequest {
    param(
        [Parameter(Mandatory = $true)][System.Net.Sockets.TcpClient]$Client
    )

    $stream = $Client.GetStream()
    $buffer = New-Object byte[] 8192
    $data = New-Object System.Collections.Generic.List[byte]

    do {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        for ($i = 0; $i -lt $read; $i++) { $data.Add($buffer[$i]) }
        $textSoFar = [System.Text.Encoding]::ASCII.GetString($data.ToArray())
        $headerEnd = $textSoFar.IndexOf("`r`n`r`n")
        if ($headerEnd -ge 0) {
            $headersText = $textSoFar.Substring(0, $headerEnd)
            $contentLength = 0
            foreach ($line in ($headersText -split "`r`n")) {
                if ($line -match "^Content-Length:\s*(\d+)") {
                    $contentLength = [int]$matches[1]
                }
            }
            $bodyStart = $headerEnd + 4
            if (($data.Count - $bodyStart) -ge $contentLength) { break }
        }
    } while ($stream.DataAvailable -or $true)

    $bytes = $data.ToArray()
    $headerTextForSplit = [System.Text.Encoding]::ASCII.GetString($bytes)
    $headerEnd = $headerTextForSplit.IndexOf("`r`n`r`n")
    if ($headerEnd -lt 0) {
        $headers = $headerTextForSplit
        $body = ""
    }
    else {
        $headers = $headerTextForSplit.Substring(0, $headerEnd)
        $bodyStart = $headerEnd + 4
        $bodyLength = [Math]::Max(0, $bytes.Length - $bodyStart)
        $bodyBytes = New-Object byte[] $bodyLength
        if ($bodyLength -gt 0) {
            [Array]::Copy($bytes, $bodyStart, $bodyBytes, 0, $bodyLength)
        }
        $contentType = ""
        foreach ($line in ($headers -split "`r`n")) {
            if ($line -match "^Content-Type:\s*(.+)$") {
                $contentType = $matches[1]
                break
            }
        }
        $body = ConvertFrom-RequestBodyBytes -Bytes $bodyBytes -ContentType $contentType
    }
    $requestLine = ($headers -split "`r`n")[0]
    $segments = $requestLine -split " "

    return [pscustomobject]@{
        Method = if ($segments.Count -gt 0) { $segments[0] } else { "" }
        Path = if ($segments.Count -gt 1) { ($segments[1] -split "\?")[0] } else { "" }
        Body = $body
    }
}

function Send-TcpResponse {
    param(
        [Parameter(Mandatory = $true)][System.Net.Sockets.TcpClient]$Client,
        [int]$Status = 200,
        [string]$Body = "OK",
        [string]$ContentType = "text/plain; charset=utf-8"
    )

    $reason = switch ($Status) {
        200 { "OK" }
        404 { "Not Found" }
        default { "OK" }
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $Status $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream = $Client.GetStream()
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Flush()
}

$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $script:ReceiverScriptDir "notification_config.json"
}
$config = Read-Config -Path $ConfigPath
$aliasesPath = Join-Path $script:ReceiverScriptDir "place_aliases.json"
$placeAliases = @()
if (Test-Path -LiteralPath $aliasesPath) {
    try {
        $placeAliases = Get-Content -Path $aliasesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $placeAliases = @()
    }
}

$eventsPath = Join-Path $resolvedOutput "notifications.jsonl"
$placesPath = Join-Path $resolvedOutput "places.csv"
$ignoredPath = Join-Path $resolvedOutput "ignored_notifications.jsonl"
$parserDiagnosticsPath = Join-Path $resolvedOutput "parser_diagnostics.jsonl"
$receiverErrorsPath = Join-Path $resolvedOutput "receiver_errors.jsonl"
$testEventsPath = Join-Path $resolvedOutput "test_notifications.jsonl"
$testIgnoredPath = Join-Path $resolvedOutput "test_ignored_notifications.jsonl"
if (-not (Test-Path $eventsPath)) { New-Item -ItemType File -Path $eventsPath | Out-Null }
if (-not (Test-Path $ignoredPath)) { New-Item -ItemType File -Path $ignoredPath | Out-Null }
if (-not (Test-Path $parserDiagnosticsPath)) { New-Item -ItemType File -Path $parserDiagnosticsPath | Out-Null }
if (-not (Test-Path $receiverErrorsPath)) { New-Item -ItemType File -Path $receiverErrorsPath | Out-Null }
if (-not (Test-Path $testEventsPath)) { New-Item -ItemType File -Path $testEventsPath | Out-Null }
if (-not (Test-Path $testIgnoredPath)) { New-Item -ItemType File -Path $testIgnoredPath | Out-Null }
Ensure-PlacesFile -Path $placesPath
if ($script:LocationResolverAvailable) {
    try {
        Initialize-LocationResolver -DataDir $resolvedOutput | Out-Null
    }
    catch {
        Write-Host "[DrivePilot Resolver] initialize failed: $($_.Exception.Message)"
    }
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($ListenAddress), $Port)
$listener.Start()

Write-Host "LINE notification receiver listening:"
Write-Host "  http://$ListenAddress`:$Port/notify"
Write-Host "  local health: http://127.0.0.1:$Port/health"
if ($ListenAddress -eq "0.0.0.0") {
    Write-Host "  LAN access: http://<computer-ip>:$Port/notify"
}
elseif ($ListenAddress -eq "127.0.0.1") {
    Write-Host "  http://localhost:$Port/notify"
}
Write-Host "Output: $resolvedOutput"
Write-Host "Press Ctrl+C to stop."

try {
    while ($true) {
        $client = $null
        $request = $null
        try {
        $client = $listener.AcceptTcpClient()
        $request = Read-HttpRequest -Client $client

        if ($request.Method -eq "GET" -and $request.Path -eq "/health") {
            Send-TcpResponse -Client $client -Body "OK"
            $client.Close()
            continue
        }

        if ($request.Method -ne "POST" -or $request.Path -ne "/notify") {
            Send-TcpResponse -Client $client -Status 404 -Body "Not found"
            $client.Close()
            continue
        }

        $payload = Get-JsonBody -Body $request.Body
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $group = Get-GroupName -Payload $payload
        $text = Get-NotificationText -Payload $payload
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = Normalize-Text ([string]$payload)
        }
        $isTestMode = ($payload.PSObject.Properties.Name -contains "test_mode") -and ([bool]$payload.test_mode)

        $decision = Test-ShouldProcessNotification -Payload $payload -Group $group -Text $text -Config $config
        if (-not $decision.process) {
            $ignoredPackage = if ([string]::IsNullOrWhiteSpace([string]$decision.package) -and ($payload.PSObject.Properties.Name -contains "package")) { [string]$payload.package } else { [string]$decision.package }
            $ignored = [pscustomobject]@{
                timestamp = $timestamp
                package = $ignoredPackage
                title = $group
                reason = $decision.reason
                text = $text
            }
            if ($ignoredPackage -eq "jp.naver.line.android") {
                $ignoredRecord = [pscustomobject]@{
                    timestamp = $timestamp
                    group = $group
                    kind = "ignored"
                    text = $text
                    notification_time = ""
                    note = ""
                    price_note = ""
                    addresses = @()
                    places = @()
                    times = @()
                    raw = $payload
                }
                if (-not $isTestMode) {
                    Add-Utf8Line -Path $eventsPath -Line ($ignoredRecord | ConvertTo-Json -Depth 8 -Compress)
                }
            }
            $ignoredDiagnostic = New-ParserDiagnostic -Timestamp $timestamp -Group $group -Text $text -Package $ignoredPackage -PlaceCandidates @() -Kind "ignored" -IgnoredReason ([string]$decision.reason)
            Add-Utf8Line -Path $parserDiagnosticsPath -Line ($ignoredDiagnostic | ConvertTo-Json -Depth 8 -Compress)
            $targetIgnoredPath = if ($isTestMode) { $testIgnoredPath } else { $ignoredPath }
            Add-Utf8Line -Path $targetIgnoredPath -Line ($ignored | ConvertTo-Json -Depth 6 -Compress)
            Write-Host "[$timestamp] ignored package=$($decision.package) title=$group reason=$($decision.reason)"
            Send-TcpResponse -Client $client -ContentType "application/json; charset=utf-8" -Body (@{
                ok = $true
                ignored = $true
                test_mode = $isTestMode
                reason = $decision.reason
            } | ConvertTo-Json -Compress)
            $client.Close()
            continue
        }

        $times = @(Get-TimeCandidates -Text $text)
        $notificationTime = if ($times.Count -gt 0) { $times[0] } else { "" }
        $note = Get-Note -Text $text
        $priceNote = Get-PriceNote -Text $text
        $baseKind = Get-Kind -Text $text
        $personalAlert = Test-PersonalAlert -Payload $payload -Group $group -Text $text -Config $config
        $tags = @()
        if ([bool]$personalAlert.is_personal_alert) {
            $tags += "personal_alert"
            $tags += "dispatcher_private"
            Write-Host "[DrivePilot] personal_alert=true source=message reason=$($personalAlert.reason) keyword=$($personalAlert.keyword)"
        }
        else {
            Write-Host "[DrivePilot] personal_alert=false source=message_only keyword="
        }
        $isDriverReply = Test-DriverReply -Text $text
        $placeCandidates = @(Get-PlaceCandidates -Text $text -City $DefaultCity -Aliases $placeAliases -DefaultKind $baseKind -DefaultNote $note)
        if ($isDriverReply) { $placeCandidates = @() }
        $addresses = @($placeCandidates | ForEach-Object { $_.address })
        $kind = $baseKind
        if ($isDriverReply) {
            $kind = "driver_reply"
        }
        elseif ([bool]$personalAlert.is_personal_alert -and $addresses.Count -eq 0 -and $baseKind -in @("", "general", "unknown", "place")) {
            $kind = "dispatcher_private"
        }
        $package = if ($payload.PSObject.Properties.Name -contains "package") { [string]$payload.package } else { [string]$decision.package }

        $record = [pscustomobject]@{
            timestamp = $timestamp
            group = $group
            kind = $kind
            text = $text
            notification_time = $notificationTime
            note = $note
            price_note = $priceNote
            addresses = $addresses
            places = $placeCandidates
            times = $times
            tags = $tags
            dispatcher_private = [bool]$personalAlert.is_personal_alert
            dispatcher_keyword = [string]$personalAlert.keyword
            personal_alert = [bool]$personalAlert.is_personal_alert
            personal_alert_reason = [string]$personalAlert.reason
            personal_alert_keyword = [string]$personalAlert.keyword
            raw = $payload
        }
        $diagnostic = New-ParserDiagnostic -Timestamp $timestamp -Group $group -Text $text -Package $package -PlaceCandidates $placeCandidates -Kind $kind -IgnoredReason "" -IsDriverReply $isDriverReply
        Add-Utf8Line -Path $parserDiagnosticsPath -Line ($diagnostic | ConvertTo-Json -Depth 8 -Compress)

        if ($isTestMode) {
            Add-Utf8Line -Path $testEventsPath -Line ($record | ConvertTo-Json -Depth 8 -Compress)
        }
        else {
            Add-Utf8Line -Path $eventsPath -Line ($record | ConvertTo-Json -Depth 8 -Compress)
            if ([bool]$personalAlert.is_personal_alert -and -not $isDriverReply) {
                $addressSummary = ($addresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 3) -join " / "
                Send-PersonalAlertDiscord -Group $group -Text $text -SystemTime $timestamp -Keyword ([string]$personalAlert.keyword) -Reason ([string]$personalAlert.reason) -AddressSummary $addressSummary -NotificationTime $notificationTime
            }
            $placeWritten = $false
            foreach ($place in $placeCandidates) {
                $address = [string]$place.address
                if (-not (Test-DuplicatePlace -Path $placesPath -Timestamp $timestamp -Group $group -Address $address)) {
                    $placeKind = if ([string]::IsNullOrWhiteSpace([string]$place.kind)) { $kind } else { [string]$place.kind }
                    $confidence = if ([string]::IsNullOrWhiteSpace([string]$place.confidence)) { Get-AddressConfidence -Address $address } else { [string]$place.confidence }
                    $placeNote = (($note, [string]$place.note) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join " / "
                    Add-Utf8Line -Path $placesPath -Line ((ConvertTo-CsvField $timestamp) + "," + (ConvertTo-CsvField $group) + "," + (ConvertTo-CsvField $placeKind) + "," + (ConvertTo-CsvField $address) + "," + (ConvertTo-CsvField $confidence) + "," + (ConvertTo-CsvField $notificationTime) + "," + (ConvertTo-CsvField $placeNote) + "," + (ConvertTo-CsvField $priceNote) + "," + (ConvertTo-CsvField $text))
                    if ($script:LocationResolverAvailable) {
                        try {
                            Resolve-DrivePilotLocation -Timestamp $timestamp -Group $group -Address $address -Kind $placeKind -Text $text | Out-Null
                        }
                        catch {
                            Write-Host "[DrivePilot Resolver] event failed: $($_.Exception.Message)"
                        }
                    }
                    $placeWritten = $true
                    # DrivePilot v1.1: locatable addresses update maps/dashboards only.
                    # Discord pushes are reserved for personal alerts, hot zone summaries, and health alerts.
                }
            }
            if ($placeWritten) {
                Update-HotZones -DataDir $resolvedOutput
            }
        }

        Write-Host "[$timestamp] $group addresses=$($addresses.Count) times=$($times.Count)"
        Send-TcpResponse -Client $client -ContentType "application/json; charset=utf-8" -Body (@{
            ok = $true
            test_mode = $isTestMode
            group = $group
            addresses = $addresses
            times = $times
        } | ConvertTo-Json -Compress)
        $client.Close()
        }
        catch {
            $errorTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $errorRecord = [pscustomobject]@{
                timestamp = $errorTimestamp
                path = if ($null -ne $request) { [string]$request.Path } else { "" }
                method = if ($null -ne $request) { [string]$request.Method } else { "" }
                error = $_.Exception.Message
                type = $_.Exception.GetType().FullName
                stack = [string]$_.ScriptStackTrace
            }
            try {
                Add-Utf8Line -Path $receiverErrorsPath -Line ($errorRecord | ConvertTo-Json -Depth 6 -Compress)
            }
            catch {}
            Write-Host "[$errorTimestamp] receiver_error $($_.Exception.Message)"
            if ($null -ne $client) {
                try {
                    Send-TcpResponse -Client $client -Status 500 -ContentType "application/json; charset=utf-8" -Body (@{
                        ok = $false
                        error = "receiver_error"
                    } | ConvertTo-Json -Compress)
                }
                catch {}
            }
        }
        finally {
            if ($null -ne $client) {
                try { $client.Close() } catch {}
            }
        }
    }
}
finally {
    $listener.Stop()
}


















