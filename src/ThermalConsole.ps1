<#
.SYNOPSIS
    Console version: reads every temperature sensor on this laptop (CPU package/cores, GPU,
    SSD, battery, ACPI zones, ...) and logs them. For the window with graphs use ThermalUI.ps1.

.DESCRIPTION
    Needs Administrator rights (the script re-launches itself elevated).
    CPU core temperatures need the PawnIO driver (the script offers to install it).
    Settings live in thermal-monitor\config.json.

    Output: thermal-monitor\data\thermal_log.csv - ONE file for all runs:
      one row per reading, one column per sensor (all values in degrees C).
      New sensors add a column; readings are appended run after run.

.EXAMPLE
    .\ThermalConsole.ps1                 # one reading
    .\ThermalConsole.ps1 -Watch          # refresh every IntervalSeconds (config.json) until Ctrl+C
    .\ThermalConsole.ps1 -Watch -Interval 10
#>
param(
    [switch]$Watch,
    [ValidateRange(1, 3600)][int]$Interval,
    [switch]$NoElevate,      # run without admin (very few sensors will be readable)
    [switch]$SkipPawnIOCheck,
    [switch]$AllHardware     # also probe motherboard Super I/O, RAM SPD, USB controllers, PSUs
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # thermal-monitor\src
$AppRoot   = Split-Path -Parent $ScriptDir                      # thermal-monitor
$OutDir    = Join-Path $AppRoot 'data'
. (Join-Path $ScriptDir 'ThermalCore.ps1')
. (Join-Path $ScriptDir 'ThermalCsv.ps1')

$config = Get-ThermalConfig $AppRoot
if (-not $PSBoundParameters.ContainsKey('Interval')) { $Interval = $config.IntervalSeconds }
$useAllHardware = $AllHardware -or $config.AllHardware
$Deg = [char]0xB0

# ---------------------------------------------------------------- elevation
$isAdmin = Test-IsAdmin
if (-not $isAdmin -and -not $NoElevate) {
    Write-Host 'Administrator rights are required to read hardware sensors. Re-launching elevated...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
    if ($Watch)           { $argList += '-Watch' }
    if ($SkipPawnIOCheck) { $argList += '-SkipPawnIOCheck' }
    if ($AllHardware)     { $argList += '-AllHardware' }
    $argList += @('-Interval', $Interval)
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

# ---------------------------------------------------------------- PawnIO (CPU MSR access)
if ($isAdmin -and -not $SkipPawnIOCheck -and -not (Test-PawnIOInstalled)) {
    Write-Host ''
    Write-Host 'The PawnIO driver is not installed. Without it, CPU core / package temperatures cannot be read.' -ForegroundColor Yellow
    $ans = Read-Host 'Install PawnIO now via winget? (Y/N)'
    if ($ans -match '^[Yy]') {
        winget install --id namazso.PawnIO -e --accept-source-agreements --accept-package-agreements
    }
}

# ---------------------------------------------------------------- start sensors
Write-Host 'Initialising sensors...' -ForegroundColor Cyan
try { Initialize-ThermalCore $AppRoot $ScriptDir $useAllHardware }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; return }

function Show-Temps($temps, $stamp) {
    Write-Host ''
    Write-Host "=== Laptop temperatures @ $stamp ===" -ForegroundColor Cyan
    if (-not $temps) {
        Write-Host 'No temperature sensors could be read.' -ForegroundColor Red
        if (-not $isAdmin) { Write-Host 'Run as Administrator (omit -NoElevate).' -ForegroundColor Yellow }
        return
    }
    foreach ($g in ($temps | Group-Object Hardware)) {
        Write-Host ''
        Write-Host "[$($g.Group[0].Type)] $($g.Name)" -ForegroundColor White
        foreach ($t in $g.Group) {
            $color = if ($t.TempC -ge $config.HotC) { 'Red' } elseif ($t.TempC -ge $config.WarnC) { 'Yellow' } else { 'Green' }
            $extra = if ($null -ne $t.MaxC) { "   (min $($t.MinC) / max $($t.MaxC))" } else { '' }
            Write-Host ('   {0,-34} ' -f $t.Sensor) -NoNewline
            Write-Host ("{0,6:N1} ${Deg}C" -f $t.TempC) -ForegroundColor $color -NoNewline
            Write-Host $extra -ForegroundColor DarkGray
        }
    }
    $hot = $temps | Sort-Object TempC -Descending | Select-Object -First 1
    Write-Host ''
    Write-Host ("Sensors read: {0}   Hottest: {1} / {2} = {3} ${Deg}C" -f @($temps).Count, $hot.Hardware, $hot.Sensor, $hot.TempC) -ForegroundColor Cyan
    if (-not ($temps | Where-Object { $_.Type -match '^Gpu' -or $_.Sensor -match '^GPU' })) {
        Write-Host "GPU temperature: not exposed ($(Get-GpuDiagnostic))" -ForegroundColor DarkYellow
        if ($script:LenovoNote) { Write-Host "Lenovo sensors: $($script:LenovoNote)" -ForegroundColor DarkYellow }
    }
}

# ---------------------------------------------------------------- main loop
New-Item -ItemType Directory -Force $OutDir | Out-Null
$csvPath = Join-Path $OutDir 'thermal_log.csv'   # single file, one row per reading
$pending = New-Object System.Collections.ArrayList

try {
    do {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $temps   = @(Read-AllTemps)
        $metrics = @(Read-AllMetrics)
        if ($Watch) { Clear-Host }
        Show-Temps $temps $stamp
        if ($metrics.Count -gt 0) {
            Write-Host ('Power / load / clock: ' + (($metrics | ForEach-Object { "$($_.Sensor) $($_.Value) $($_.Unit)" }) -join '   ')) -ForegroundColor Cyan
        }

        if ($temps.Count -gt 0) { [void]$pending.Add((ConvertTo-ThermalRow $temps $stamp $metrics)) }
        try {
            Save-ThermalRows $csvPath $pending.ToArray()
            $pending.Clear()
            Write-Host "Saved: $csvPath" -ForegroundColor DarkGray
        } catch {
            # Usually the CSV is open in Excel (file locked). Keep the rows and retry next time.
            Write-Host "Could not write $csvPath ($($_.Exception.Message.Trim())). $($pending.Count) reading(s) kept in memory - close the file and they will be saved on the next refresh." -ForegroundColor Yellow
        }
        if ($Watch) {
            Write-Host "Refreshing every $Interval s - press Ctrl+C to stop." -ForegroundColor DarkGray
            Start-Sleep -Seconds $Interval
        }
    } while ($Watch)
}
finally {
    Close-ThermalCore
}
