# Helpers that store readings in ONE wide CSV: one row per reading, one column per sensor (°C).
# Dot-sourced by ThermalConsole.ps1 and ThermalUI.ps1.
#
#   Timestamp, CPU Package (°C), CPU Core Max (°C), ..., GPU Core (°C), SSD Composite (°C), ...
#
# Left out on purpose (redundant or constant):
#   "... Distance to TjMax"  = TjMax - core temperature
#   SSD "Warning/Critical Temperature" = fixed thresholds, not measurements

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Get-ThermalColumnName($t, [int]$storageCount, [hashtable]$storageIndex) {
    if ($t.Type -eq 'Metric') { return "$($t.Sensor) ($($t.Unit))" }      # e.g. "CPU Power (W)"
    $s = $t.Sensor -replace ' #(\d+)', ' $1'
    switch -Regex ($t.Type) {
        '^Cpu$'     { $n = if ($s -match '^CPU ') { $s } else { "CPU $s" } }
        '^Gpu'      { $n = 'GPU ' + ($s -replace '^GPU ', '') }
        '^Storage$' {
            $s = $s -replace ' Temperature$', '' -replace '^Temperature ', 'Sensor '
            $p = if ($storageCount -gt 1) { "SSD$($storageIndex[$t.Hardware])" } else { 'SSD' }
            $n = "$p $s"
        }
        '^Battery$'   { $n = "Battery $s" }
        '^Lenovo'     { $n = 'Lenovo ' + ($s -replace ' \(EC\)$', '') }
        '^ThermalZone$' { $n = "ACPI $s" }
        default       { $n = "$($t.Type) $s" }
    }
    "$n ($([char]0xB0)C)"
}

function Get-ThermalColumnRank([string]$c) {
    switch -Regex ($c) {
        '^Timestamp$'          { return 0 }
        '^CPU Package'         { return 1 }
        '^CPU Core Max'        { return 2 }
        '^CPU Core Average'    { return 3 }
        '^CPU P-Core (\d+)'    { return 10 + [int]$Matches[1] }
        '^CPU E-Core (\d+)'    { return 40 + [int]$Matches[1] }
        '^CPU Power'           { return 601 }
        '^CPU Load'            { return 602 }
        '^CPU Clock Avg'       { return 603 }
        '^CPU Clock Max'       { return 604 }
        '^GPU Power'           { return 611 }
        '^GPU Load'            { return 612 }
        '^CPU '                { return 90 }
        '^GPU '                { return 100 }
        '^SSD'                 { return 200 }
        '^Battery'             { return 300 }
        '^Lenovo'              { return 400 }
        '^ACPI'                { return 500 }
        default                { return 900 }
    }
}

function Sort-ThermalColumns([string[]]$cols) {
    $cols | Sort-Object @{ e = { Get-ThermalColumnRank $_ } }, @{ e = { $_ } } -Unique
}

# Turn one reading (temperature objects + optional power/load/clock metrics) into an ordered row.
function ConvertTo-ThermalRow($temps, [string]$stamp, $metrics = @()) {
    $keep = @($temps | Where-Object {
        $_.Sensor -notmatch 'Distance to TjMax$' -and
        -not ($_.Type -eq 'Storage' -and $_.Sensor -match '^(Warning|Critical) Temperature$')
    })
    $drives = @($keep | Where-Object Type -eq 'Storage' | Select-Object -ExpandProperty Hardware -Unique)
    $idx = @{}; for ($i = 0; $i -lt $drives.Count; $i++) { $idx[$drives[$i]] = $i + 1 }

    $row = [ordered]@{ Timestamp = $stamp }
    foreach ($t in $keep) {
        $col = Get-ThermalColumnName $t $drives.Count $idx
        if (-not $row.Contains($col)) { $row[$col] = ([double]$t.TempC).ToString('0.0', $script:Inv) }
    }
    foreach ($m in @($metrics)) {
        if (-not $m) { continue }
        $col = Get-ThermalColumnName $m 0 @{}
        $fmt = switch ($m.Unit) { 'GHz' { '0.00' } default { '0.0' } }
        if (-not $row.Contains($col)) { $row[$col] = ([double]$m.Value).ToString($fmt, $script:Inv) }
    }
    $row
}

# Split one CSV line on commas that are outside quotes, and strip the quotes.
function Split-ThermalCsvLine([string]$line) {
    @([regex]::Split($line, ',(?=(?:[^"]*"[^"]*")*[^"]*$)') | ForEach-Object { $_.Trim().Trim('"') })
}

# Read the readings logged since $since (oldest first), without loading the whole file into objects.
# Returns objects: @{ Time = [datetime]; Values = ordered @{ 'CPU Package (°C)' = 54.0; ... } }
# Opens the file with shared access, so it works while the logger (or Excel) has it open.
function Read-RecentThermalRows([string]$path, [datetime]$since) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $lines = New-Object System.Collections.Generic.List[string]
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
        while ($null -ne ($l = $sr.ReadLine())) { if ($l.Trim()) { $lines.Add($l) } }
    } finally { $fs.Dispose() }
    if ($lines.Count -lt 2) { return @() }

    $header = Split-ThermalCsvLine $lines[0]
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = $lines.Count - 1; $i -ge 1; $i--) {          # newest rows are at the end
        $f = Split-ThermalCsvLine $lines[$i]
        $t = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($f[0], 'yyyy-MM-dd HH:mm:ss', $script:Inv, 'None', [ref]$t) -and
            -not [datetime]::TryParse($f[0], [ref]$t)) { continue }
        if ($t -lt $since) { break }
        $vals = [ordered]@{}
        for ($j = 1; $j -lt [math]::Min($f.Count, $header.Count); $j++) {
            $v = 0.0
            if ($f[$j] -ne '' -and [double]::TryParse($f[$j], [Globalization.NumberStyles]::Float, $script:Inv, [ref]$v)) { $vals[$header[$j]] = $v }
        }
        $out.Add([pscustomobject]@{ Time = $t; Values = $vals })
    }
    $out.Reverse()
    $out.ToArray()   # unrolled to the caller; wrap the call in @() to always get an array
}

# Append rows to the single CSV. If new sensors appear, the file is rewritten once with the
# extra columns (old rows get blanks there). Throws IOException if the file is locked (e.g. open in Excel).
function Save-ThermalRows([string]$path, $rows) {
    if (-not $rows -or @($rows).Count -eq 0) { return }
    $rowCols = @($rows | ForEach-Object { $_.Keys }) | Select-Object -Unique

    $header = @()
    if (Test-Path -LiteralPath $path) {
        $first = Get-Content -LiteralPath $path -TotalCount 1 -Encoding UTF8
        if ($first) { $header = @($first.Split(',') | ForEach-Object { $_.Trim('"') }) }
    }
    $newCols = @($rowCols | Where-Object { $header -notcontains $_ })
    $toObj = { param($r, $cols) $o = [ordered]@{}; foreach ($c in $cols) { $o[$c] = if ($r.Contains($c)) { $r[$c] } else { '' } }; [pscustomobject]$o }

    if ($header.Count -eq 0) {
        $cols = Sort-ThermalColumns $rowCols
        $rows | ForEach-Object { & $toObj $_ $cols } | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    }
    elseif ($newCols.Count -eq 0) {
        $rows | ForEach-Object { & $toObj $_ $header } | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 -Append
    }
    else {
        $cols = Sort-ThermalColumns ($header + $newCols)
        $old = @(Import-Csv -LiteralPath $path -Encoding UTF8)
        $tmp = "$path.tmp"
        @($old | Select-Object $cols) + @($rows | ForEach-Object { & $toObj $_ $cols }) |
            Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
}
