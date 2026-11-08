# Shared sensor engine used by ThermalConsole.ps1 and ThermalUI.ps1.
# Dot-source this file, then call Initialize-ThermalCore. Needs Administrator rights for most sensors.
#
# Sources:
#   - LibreHardwareMonitorLib (CPU cores/package, SSD, battery)       -> <app>\lib, hash-verified
#   - PawnIO IntelMCHBAR module (Meteor Lake iGPU temperature)        -> <app>\lib, hash-verified
#   - Intel Graphics Control Library / Windows WDDM (GPU, if reported) -> IntelGpuTemp.cs
#   - Lenovo WMI, Windows ACPI thermal zones

$script:LhmVersion = 'v0.9.6'
$script:LhmUrl     = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/$($script:LhmVersion)/LibreHardwareMonitor.zip"
$script:ModulesUrl = 'https://github.com/namazso/PawnIO.Modules/releases/download/0.2.11/release_0_2_11.zip'

# ---------------------------------------------------------------- pinned hashes (SHA-256)
# Everything loaded while running as Administrator is checked against these values.
# Zip hashes match the digests GitHub publishes for the official release assets.
$script:LhmZipHash = '086D9F1B5A99E643EDC2CFAAAC16051685B551E4C5AC0B32A57C58C0E529C001'
$script:LibHashes  = [ordered]@{   # only the DLLs LibreHardwareMonitorLib actually references
    'LibreHardwareMonitorLib.dll'                = '6EBC194316536BA61AF5BE24508AD9FCBB2ECC685E716C12E787C79530F66BF0'
    'BlackSharp.Core.dll'                        = 'CAFB93AFCC8D8A367E21F619673D05C06887D8964867FED1371F02DED1CD3E23'
    'DiskInfoToolkit.dll'                        = '1ACBF51B3C10C51C986CF43021680D34A2E38D9A5BA652BCFA9A1B5F7FC09800'
    'HidSharp.dll'                               = 'D86690EFDE30EA9179F669320F39148853793B743A98B531AFEAF30598E22F54'
    'RAMSPDToolkit-NDD.dll'                      = 'B6882354C7C8EC186617E421507743DBFAE09C5C1FC24CEF76A1D0C0C26651DE'
    'System.Buffers.dll'                         = '2D78D770C9CB997199154AE8C018B9F1D1EFBC86729F7264DDE6DBAD2A12CAC3'
    'System.Memory.dll'                          = 'D5E8E4866F9CFA66F7765660F84B210198893E55335487AFE5EBDA342C0E913D'
    'System.Numerics.Vectors.dll'                = '20C2FA81B8C70D651099D762954F285FD4F942E63B2D7217C145DAB8D4B2F4C9'
    'System.Runtime.CompilerServices.Unsafe.dll' = '08CBD7278B66F1E68425A82D4B97181A4130D93E3DD91831407ABA7212CCDACF'
}
$script:ModulesZipHash = '43608CB89BC84247FEF1368A139013F7D043E17DB6D6C8DFC9B46BF0905A81F4'
$script:MchbarBinHash  = '3F82B832D99B4AAC37D2A20FDB7C9BAA2A3BC0488612C9019C9484EB0E8A6EAE'

$script:IgclOk = $false
$script:MchbarOk = $false
$script:LenovoNote = ''
$script:computer = $null

# ---------------------------------------------------------------- helpers
function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PawnIOInstalled {
    [bool](Get-Service -Name 'PawnIO*' -ErrorAction SilentlyContinue) -or (Test-Path "$env:ProgramFiles\PawnIO\PawnIOLib.dll")
}

function Get-VerifiedDownload($url, $expectedHash) {
    # Download into a fresh, randomly named folder so nothing pre-planted in %TEMP% can be picked up.
    $work = Join-Path ([IO.Path]::GetTempPath()) ("thermal_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $work | Out-Null
    $zip = Join-Path $work 'download.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $expectedHash) {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        throw "Download from $url failed its SHA-256 check - refusing to use it."
    }
    Expand-Archive $zip (Join-Path $work 'x')
    return $work
}

function Test-FileHash($path, $expected) {
    (Test-Path -LiteralPath $path -PathType Leaf) -and ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $expected)
}

# ---------------------------------------------------------------- config (<app>\config.json)
function Get-ThermalConfig([string]$AppRoot) {
    $defaults = [ordered]@{
        IntervalSeconds = 5        # how often to read sensors (1 - 3600)
        HistoryMinutes  = 15       # how much history the graph shows
        AverageEnabled  = $false   # graph shows moving averages instead of raw readings
        AverageSeconds  = 30       # moving-average window (5 - 3600)
        LogToCsv        = $true    # append every reading to data\thermal_log.csv
        WarnC           = 75       # yellow from this temperature
        HotC            = 90       # red from this temperature
        AllHardware     = $false   # also probe Super I/O, RAM SPD, USB controllers, PSUs
        SensorsCollapsed = $false  # window: sensor list hidden (graph uses full width)
        CollapsedGroups = @()      # window: sensor groups folded in the list (e.g. "CPU")
        ChartSensors    = @('CPU Package', 'CPU Core Max', 'GPU Core', 'SSD Composite')
    }
    $path = Join-Path $AppRoot 'config.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($defaults.Keys)) { if ($null -ne $j.$k) { $defaults[$k] = $j.$k } }
        } catch { Write-Warning "config.json is invalid, using defaults: $($_.Exception.Message)" }
    }
    # validate
    $defaults.IntervalSeconds = [math]::Min(3600, [math]::Max(1, [int]$defaults.IntervalSeconds))
    $defaults.HistoryMinutes  = [math]::Min(1440, [math]::Max(1, [int]$defaults.HistoryMinutes))
    $defaults.AverageSeconds  = [math]::Min(3600, [math]::Max(5, [int]$defaults.AverageSeconds))
    $defaults.AverageEnabled  = [bool]$defaults.AverageEnabled
    $defaults.WarnC = [double]$defaults.WarnC; $defaults.HotC = [double]$defaults.HotC
    $defaults.LogToCsv = [bool]$defaults.LogToCsv; $defaults.AllHardware = [bool]$defaults.AllHardware
    $defaults.SensorsCollapsed = [bool]$defaults.SensorsCollapsed
    $defaults.ChartSensors = @($defaults.ChartSensors | ForEach-Object { [string]$_ })
    $defaults.CollapsedGroups = @($defaults.CollapsedGroups | ForEach-Object { [string]$_ })
    if (-not (Test-Path -LiteralPath $path)) { Save-ThermalConfig $AppRoot $defaults }
    $defaults
}

function Save-ThermalConfig([string]$AppRoot, $config) {
    $path = Join-Path $AppRoot 'config.json'
    ([pscustomobject]$config) | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $path -Encoding UTF8
}

# ---------------------------------------------------------------- initialise
function Initialize-ThermalCore([string]$AppRoot, [string]$SrcDir, [bool]$AllHardware = $false) {
    $script:isAdmin = Test-IsAdmin
    $script:LibDir  = Join-Path $AppRoot 'lib'
    $LibDir = $script:LibDir
    $dll = Join-Path $LibDir 'LibreHardwareMonitorLib.dll'
    New-Item -ItemType Directory -Force $LibDir | Out-Null

    # Remove DLLs that are not on the allow-list (e.g. GUI-only files from older versions).
    Get-ChildItem $LibDir -Filter *.dll | Where-Object { -not $script:LibHashes.Contains($_.Name) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $missing = @($script:LibHashes.Keys | Where-Object { -not (Test-Path (Join-Path $LibDir $_)) })
    if ($missing.Count -gt 0) {
        Write-Host "Downloading LibreHardwareMonitor $($script:LhmVersion) (one-time)..." -ForegroundColor Cyan
        $work = Get-VerifiedDownload $script:LhmUrl $script:LhmZipHash
        foreach ($name in $script:LibHashes.Keys) { Copy-Item (Join-Path $work "x\$name") $LibDir -Force }
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Integrity check before anything is loaded with admin rights.
    $tampered = @($script:LibHashes.Keys | Where-Object { -not (Test-FileHash (Join-Path $LibDir $_) $script:LibHashes[$_]) })
    if ($tampered.Count -gt 0) {
        throw ("SECURITY: these files in $LibDir do not match the official release: " + ($tampered -join ', ') +
               ". Refusing to load them. Delete the lib folder and run again to re-download verified copies.")
    }
    Get-ChildItem $LibDir -File | Unblock-File -ErrorAction SilentlyContinue

    # Resolve dependency DLLs from .\lib (PowerShell does not apply binding redirects).
    # Only allow-listed, hash-verified names are ever loaded.
    if (-not ('LhmResolver' -as [type])) {
        Add-Type -TypeDefinition @"
using System; using System.IO; using System.Reflection; using System.Collections.Generic;
public static class LhmResolver {
    static string dir; static HashSet<string> allowed; static bool registered;
    public static void Register(string d, string[] names) {
        dir = d; allowed = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase);
        if (registered) return; registered = true;
        AppDomain.CurrentDomain.AssemblyResolve += (s, e) => {
            string n = new AssemblyName(e.Name).Name + ".dll";
            if (!allowed.Contains(n)) return null;
            string p = Path.Combine(dir, n);
            return File.Exists(p) ? Assembly.LoadFrom(p) : null;
        };
    }
}
"@
    }
    [LhmResolver]::Register($LibDir, [string[]]$script:LibHashes.Keys)
    Add-Type -Path $dll

    # Intel GPU readers (Intel Graphics Control Library, Windows WDDM, PawnIO MCHBAR).
    $env:ZES_ENABLE_SYSMAN = '1'   # Level Zero telemetry must be enabled before init
    try {
        if (-not ('IntelGpuTemp' -as [type])) { Add-Type -Path (Join-Path $SrcDir 'IntelGpuTemp.cs') }
        $script:IgclOk = $true
    } catch { Write-Warning "Intel GPU reader unavailable: $($_.Exception.Message)" }

    $script:GpuName  = (Get-CimInstance Win32_VideoController | Where-Object Name -match 'Intel' | Select-Object -First 1).Name
    $script:cpuInfo  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $script:IsMeteorLake = $script:cpuInfo.Manufacturer -match 'Intel' -and $script:cpuInfo.Caption -match 'Family 6 Model (170|172)\b'
    $script:IsLenovo = (Get-CimInstance Win32_ComputerSystem).Manufacturer -match 'LENOVO'

    # Meteor Lake iGPU temperature: Intel's driver reports it as unsupported, but the hardware
    # register THERM_STATUS_GT still has it (LibreHardwareMonitor PR #2551). Read-only module.
    $pawnIoLib = Join-Path $env:ProgramFiles 'PawnIO\PawnIOLib.dll'
    $mchbarBin = Join-Path $LibDir 'IntelMCHBAR.bin'
    if ($script:IsMeteorLake -and $script:IgclOk -and $script:isAdmin -and (Test-Path $pawnIoLib)) {
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $pawnIoLib
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'CN=namazso\.eu') {
                throw "PawnIOLib.dll signature is not valid ($($sig.Status)) - not loading it"
            }
            if (-not (Test-Path $mchbarBin)) {
                Write-Host 'Downloading PawnIO IntelMCHBAR module (one-time)...' -ForegroundColor Cyan
                $work = Get-VerifiedDownload $script:ModulesUrl $script:ModulesZipHash
                Copy-Item (Get-ChildItem (Join-Path $work 'x') -Recurse -Filter 'IntelMCHBAR.bin' | Select-Object -First 1).FullName $mchbarBin
                Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (-not (Test-FileHash $mchbarBin $script:MchbarBinHash)) { throw 'IntelMCHBAR.bin does not match the official release - not loading it' }
            $script:MchbarOk = [MchbarGpuTemp]::Open($pawnIoLib, $mchbarBin)
        } catch { [MchbarGpuTemp]::LastError = $_.Exception.Message }
    }

    # LibreHardwareMonitor
    $c = New-Object LibreHardwareMonitor.Hardware.Computer
    $c.IsCpuEnabled         = $true
    $c.IsGpuEnabled         = $true
    $c.IsStorageEnabled     = $true
    $c.IsBatteryEnabled     = $true
    $c.IsNetworkEnabled     = $false
    # Off by default: these probe low-level buses (Super I/O ports, SMBus/RAM SPD, USB fan/RGB
    # controllers, USB PSUs). They gave no temperatures on this laptop, so they're not worth the risk.
    $c.IsMotherboardEnabled = $AllHardware
    $c.IsMemoryEnabled      = $AllHardware
    $c.IsControllerEnabled  = $AllHardware
    $c.IsPsuEnabled         = $AllHardware
    $c.Open()
    $script:computer = $c

    # First Update() on some sensors returns nothing; prime once.
    foreach ($hw in $c.Hardware) { $hw.Update() }
    Start-Sleep -Milliseconds 800
}

# ---------------------------------------------------------------- readers
function Get-HardwareTemps($hw, $parent) {
    $hw.Update()
    $hwName = if ($parent) { "$($parent.Name) / $($hw.Name)" } else { $hw.Name }
    foreach ($s in $hw.Sensors) {
        if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $null -ne $s.Value) {
            [pscustomobject]@{
                Source   = 'LibreHardwareMonitor'
                Type     = [string]$hw.HardwareType
                Hardware = $hwName
                Sensor   = $s.Name
                TempC    = [math]::Round([double]$s.Value, 1)
                MinC     = if ($null -ne $s.Min) { [math]::Round([double]$s.Min, 1) } else { $null }
                MaxC     = if ($null -ne $s.Max) { [math]::Round([double]$s.Max, 1) } else { $null }
            }
        }
    }
    foreach ($sub in $hw.SubHardware) { Get-HardwareTemps $sub $hw }
}

function Get-AcpiTemps {
    # ACPI thermal zones (admin) - values are tenths of Kelvin
    try {
        Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | ForEach-Object {
            $c = [math]::Round($_.CurrentTemperature / 10 - 273.15, 1)
            if ($c -gt 0) {
                [pscustomobject]@{ Source = 'Windows ACPI'; Type = 'ThermalZone'; Hardware = 'ACPI'
                    Sensor = ($_.InstanceName -replace '^ACPI\\ThermalZone\\', '' -replace '_0$', '')
                    TempC = $c; MinC = $null; MaxC = $null }
            }
        }
    } catch { }
    # Thermal zone performance counters (Kelvin)
    try {
        Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop | ForEach-Object {
            $k = if ($_.HighPrecisionTemperature) { $_.HighPrecisionTemperature / 10 } else { $_.Temperature }
            if ($k -gt 0) {
                [pscustomobject]@{ Source = 'Windows PerfCounter'; Type = 'ThermalZone'; Hardware = 'ACPI'
                    Sensor = $_.Name; TempC = [math]::Round($k - 273.15, 1); MinC = $null; MaxC = $null }
            }
        }
    } catch { }
}

function Get-IntelGpuTemps {
    if (-not $script:IgclOk) { return }
    try {
        foreach ($r in [IntelGpuTemp]::Read()) {
            [pscustomobject]@{ Source = 'Intel IGCL'; Type = 'GpuIntel'
                Hardware = if ($r.Adapter -eq 0 -and $script:GpuName) { $script:GpuName } else { "Intel GPU #$($r.Adapter)" }
                Sensor = $r.Sensor; TempC = $r.TempC; MinC = $null
                MaxC = if ($r.MaxC -gt 0) { [math]::Round($r.MaxC, 1) } else { $null } }
        }
    } catch { }
}

function Get-WddmGpuTemps {
    # Same source Task Manager uses (shows N/A when the driver does not report it)
    if (-not $script:IgclOk) { return }
    try {
        foreach ($r in [WddmGpuTemp]::Read()) {
            [pscustomobject]@{ Source = 'Windows WDDM'; Type = 'Gpu'; Hardware = $r.Name
                Sensor = 'GPU Temperature'; TempC = $r.TempC; MinC = $null; MaxC = $null }
        }
    } catch { }
}

function Get-LenovoTemps {
    # Lenovo BIOS/EC sensors (not implemented on every model - e.g. IdeaPad returns "Not supported").
    try {
        $gz = @(Get-CimInstance -Namespace root/WMI -ClassName LENOVO_GAMEZONE_DATA -ErrorAction Stop)[0]
        if (-not $gz) { $script:LenovoNote = 'LENOVO_GAMEZONE_DATA has no instance'; return }
        foreach ($m in @(@{ Method = 'GetCPUTemp'; Sensor = 'CPU Temperature (EC)' },
                         @{ Method = 'GetGPUTemp'; Sensor = 'GPU Temperature (EC)' },
                         @{ Method = 'GetIRTemp';  Sensor = 'IR / Skin Temperature (EC)' })) {
            try {
                $res = Invoke-CimMethod -InputObject $gz -MethodName $m.Method -ErrorAction Stop
                $v = $res.Data; if ($null -eq $v) { $v = $res.ReturnValue }
                if ($null -ne $v -and [double]$v -gt 0 -and [double]$v -lt 150) {
                    [pscustomobject]@{ Source = 'Lenovo WMI'; Type = 'Lenovo EC'; Hardware = 'Lenovo Embedded Controller'
                        Sensor = $m.Sensor; TempC = [double]$v; MinC = $null; MaxC = $null }
                }
            } catch { $script:LenovoNote = "$($m.Method): $($_.Exception.Message.Trim())" }
        }
    } catch { $script:LenovoNote = "LENOVO_GAMEZONE_DATA: $($_.Exception.Message.Trim())" }
}

function Get-MchbarGpuTemp($cpuTemps) {
    if (-not $script:MchbarOk) { return }
    # TjMax = core temperature + "distance to TjMax" (both from LibreHardwareMonitor); 110 C fallback
    $tj = 110
    $d = $cpuTemps | Where-Object { $_.Type -eq 'Cpu' -and $_.Sensor -match '^(.+) Distance to TjMax$' } | Select-Object -First 1
    if ($d) {
        $core = $d.Sensor -replace ' Distance to TjMax$', ''
        $c = $cpuTemps | Where-Object { $_.Type -eq 'Cpu' -and $_.Sensor -eq $core } | Select-Object -First 1
        if ($c) { $tj = [math]::Round($c.TempC + $d.TempC) }
    }
    $t = [MchbarGpuTemp]::Read($tj)
    if (-not [double]::IsNaN($t) -and $t -gt 0 -and $t -lt 150) {
        [pscustomobject]@{ Source = 'PawnIO MCHBAR'; Type = 'GpuIntel'
            Hardware = if ($script:GpuName) { $script:GpuName } else { 'Intel iGPU' }
            Sensor = 'GPU Core'; TempC = $t; MinC = $null; MaxC = $null }
    }
}

function Read-AllTemps {
    $list = @()
    foreach ($hw in $script:computer.Hardware) { $list += @(Get-HardwareTemps $hw $null) }
    $list += @(Get-MchbarGpuTemp $list)
    $list += @(Get-IntelGpuTemps)
    $list += @(Get-WddmGpuTemps)
    # Lenovo WMI and ACPI zones are slow to query; if they returned nothing once, stop asking.
    if ($script:IsLenovo -and -not $script:SkipLenovo) {
        $l = @(Get-LenovoTemps | Where-Object { $_ }); $list += $l
        if ($l.Count -eq 0) { $script:SkipLenovo = $true }
    }
    if (-not $script:SkipAcpi) {
        $a = @(Get-AcpiTemps | Where-Object { $_ }); $list += $a
        if ($a.Count -eq 0) { $script:SkipAcpi = $true }
    }
    @($list | Where-Object { $_ })
}

# Power / load / clock of CPU and GPU. Call right after Read-AllTemps (which refreshes the hardware).
# Returns objects: Type='Metric', Sensor = 'CPU Power' | 'CPU Load' | 'CPU Clock Avg' | 'CPU Clock Max' |
# 'GPU Power' | 'GPU Load', Value, Unit = 'W' | '%' | 'GHz'.
function Read-AllMetrics {
    if (-not $script:computer) { return @() }
    $out = New-Object System.Collections.ArrayList
    $add = { param($n, $v, $u) [void]$out.Add([pscustomobject]@{ Type = 'Metric'; Hardware = 'Metrics'; Sensor = $n; Value = [double]$v; Unit = $u }) }
    $cpuGfxPower = $null; $gpuPower = $null; $gpuLoad = $null
    foreach ($hw in $script:computer.Hardware) {
        $type = [string]$hw.HardwareType
        $sens = @($hw.Sensors | Where-Object { $null -ne $_.Value -and -not [double]::IsNaN([double]$_.Value) })
        if ($type -eq 'Cpu') {
            $p = $sens | Where-Object { [string]$_.SensorType -eq 'Power' -and $_.Name -eq 'CPU Package' } | Select-Object -First 1
            if ($p) { & $add 'CPU Power' ([math]::Round([double]$p.Value, 1)) 'W' }
            $g = $sens | Where-Object { [string]$_.SensorType -eq 'Power' -and $_.Name -match 'Graphics' } | Select-Object -First 1
            if ($g) { $cpuGfxPower = [double]$g.Value }
            $l = $sens | Where-Object { [string]$_.SensorType -eq 'Load' -and $_.Name -eq 'CPU Total' } | Select-Object -First 1
            if ($l) { & $add 'CPU Load' ([math]::Round([double]$l.Value, 1)) '%' }
            $clk = @($sens | Where-Object { [string]$_.SensorType -eq 'Clock' -and $_.Name -notmatch 'Bus' -and [double]$_.Value -gt 0 } | ForEach-Object { [double]$_.Value })
            if ($clk.Count -gt 0) {
                & $add 'CPU Clock Avg' ([math]::Round(($clk | Measure-Object -Average).Average / 1000, 2)) 'GHz'
                & $add 'CPU Clock Max' ([math]::Round(($clk | Measure-Object -Maximum).Maximum / 1000, 2)) 'GHz'
            }
        }
        elseif ($type -match '^Gpu') {
            $p = $sens | Where-Object { [string]$_.SensorType -eq 'Power' } | Sort-Object { if ($_.Name -match 'GPU Power|Package|Total') { 0 } else { 1 } } | Select-Object -First 1
            if ($p -and $null -eq $gpuPower) { $gpuPower = [double]$p.Value }
            $loads = @($sens | Where-Object { [string]$_.SensorType -eq 'Load' })
            $l = $loads | Where-Object { $_.Name -match '^(D3D 3D|GPU Core)$' } | Select-Object -First 1
            if (-not $l -and $loads.Count) { $l = $loads | Sort-Object { [double]$_.Value } -Descending | Select-Object -First 1 }
            if ($l -and $null -eq $gpuLoad) { $gpuLoad = [double]$l.Value }
        }
    }
    if ($null -eq $gpuPower) { $gpuPower = $cpuGfxPower }     # iGPU power from the CPU package (RAPL)
    if ($null -ne $gpuPower) { & $add 'GPU Power' ([math]::Round($gpuPower, 1)) 'W' }
    if ($null -ne $gpuLoad)  { & $add 'GPU Load'  ([math]::Round($gpuLoad, 1)) '%' }
    @($out)
}

function Get-GpuDiagnostic {
    if (-not $script:IgclOk) { return 'GPU reader not loaded' }
    $why = "MCHBAR: $([MchbarGpuTemp]::LastError) | Intel: $([IntelGpuTemp]::LastError) | Windows: $([WddmGpuTemp]::LastError)"
    if (-not $script:IsMeteorLake) { $why = "not a Meteor Lake CPU; $why" }
    $why
}

function Close-ThermalCore {
    if ($script:computer) { try { $script:computer.Close() } catch { }; $script:computer = $null }
    if ($script:IgclOk) { try { [IntelGpuTemp]::Close(); [MchbarGpuTemp]::Close() } catch { } }
}
