<#
.SYNOPSIS
    Thermal Monitor window: live temperatures of every sensor + graphs (VS Code "Dark Modern" look).

.DESCRIPTION
    - Reads all sensors every IntervalSeconds (default 5 s; toolbar or Settings).
    - Left: sensors grouped CPU / GPU / Storage (click a group to fold it, click a sensor to graph it),
      with current / min / max. Only rows whose values changed are repainted.
    - Right: graph of the selected sensors over the last HistoryMinutes, loaded from data\thermal_log.csv
      on start. Optional moving average (Average + window). Hover for a crosshair with all values.
    - Settings window for every option in config.json.
    Needs Administrator rights (re-launches itself elevated).
#>
param([switch]$NoElevate)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # thermal-monitor\src
$AppRoot   = Split-Path -Parent $ScriptDir                      # thermal-monitor
$OutDir    = Join-Path $AppRoot 'data'

. (Join-Path $ScriptDir 'ThermalCore.ps1')
. (Join-Path $ScriptDir 'ThermalCsv.ps1')

# ---------------------------------------------------------------- elevation
if (-not (Test-IsAdmin) -and -not $NoElevate) {
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
    } catch { Write-Host 'Administrator rights were not granted.' -ForegroundColor Yellow }
    return
}

# ---------------------------------------------------------------- WinForms setup
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Windows.Forms.DataVisualization
if (-not ('ThermalUi.Native' -as [type])) {
    Add-Type -Namespace ThermalUi -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
'@
}
[void][ThermalUi.Native]::SetProcessDPIAware()       # crisp text on high-DPI laptop screens[System.Windows.Forms.Application]::EnableVisualStyles()

$gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $Scale = $gfx.DpiX / 96.0; $gfx.Dispose()
function Px([double]$n) { [int][math]::Round($n * $Scale) }
function Show-Error([string]$msg) { [void][System.Windows.Forms.MessageBox]::Show($msg, 'Thermal Monitor', 'OK', 'Error') }
function Set-DarkTitleBar($f) { $on = 1; [void][ThermalUi.Native]::DwmSetWindowAttribute($f.Handle, 20, [ref]$on, 4) }
function Enable-DoubleBuffer($ctl) {
    [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($ctl, $true, $null)
}

# ---------------------------------------------------------------- VS Code "Dark Modern" colours
function Hex([string]$h) { [System.Drawing.ColorTranslator]::FromHtml($h) }
$Theme = @{
    Editor      = Hex '#1F1F1F'   # editor background  -> graph, dialogs
    Side        = Hex '#181818'   # side bar / title / status bar -> sensor list, toolbar, status
    Border      = Hex '#2B2B2B'
    Input       = Hex '#313131'   # inputs, secondary buttons
    InputBorder = Hex '#3C3C3C'
    ButtonHover = Hex '#3C3C3C'
    ListHover   = Hex '#2A2D2E'
    Text        = Hex '#CCCCCC'
    Muted       = Hex '#9D9D9D'
    Accent      = Hex '#0078D4'
    AccentHover = Hex '#026EC1'
    HoverBg     = Hex '#202020'   # editor hover widget
    HoverBorder = Hex '#454545'
    Good        = Hex '#89D185'
    Warn        = Hex '#CCA700'
    Hot         = Hex '#F14C4C'
}
# Line colours = VS Code Dark Modern syntax colours. Key lines get a fixed colour; others take the next unused one.
$LineColors = @('#4FC1FF', '#CE9178', '#C586C0', '#4EC9B0', '#DCDCAA', '#569CD6', '#D7BA7D', '#B5CEA8',
                '#9CDCFE', '#D16969', '#6A9955', '#F44747', '#C8C8C8', '#646695', '#BB80B3', '#808080') | ForEach-Object { Hex $_ }
$FixedColors = @{
    'CPU Package' = '#4FC1FF'; 'CPU Core Max' = '#CE9178'; 'GPU Core' = '#C586C0'; 'SSD Composite' = '#4EC9B0'
    'CPU Power'   = '#DCDCAA'; 'CPU Load' = '#569CD6'; 'CPU Clock Avg' = '#6A9955'; 'CPU Clock Max' = '#B5CEA8'
    'GPU Power'   = '#D16969'; 'GPU Load' = '#BB80B3'
}
$script:colorIndex = 0
function Get-LineColor([string]$name) {
    if ($FixedColors.ContainsKey($name)) { return (Hex $FixedColors[$name]) }
    $fixed = @($FixedColors.Values | ForEach-Object { (Hex $_).ToArgb() })
    for ($k = 0; $k -lt $LineColors.Count; $k++) {
        $c = $LineColors[($script:colorIndex + $k) % $LineColors.Count]
        if ($fixed -notcontains $c.ToArgb()) { $script:colorIndex = ($script:colorIndex + $k + 1) % $LineColors.Count; return $c }
    }
    $LineColors[0]
}

$UiFont     = New-Object System.Drawing.Font('Segoe UI', 9)
$UiFontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$SmallFont  = New-Object System.Drawing.Font('Segoe UI', 8.25)
$HeaderFont = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)

$Deg = [char]0xB0
$Inv = [Globalization.CultureInfo]::InvariantCulture
$config  = Get-ThermalConfig $AppRoot
$csvPath = Join-Path $OutDir 'thermal_log.csv'
New-Item -ItemType Directory -Force $OutDir | Out-Null

# ---------------------------------------------------------------- PawnIO check
if (-not (Test-PawnIOInstalled)) {
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "The PawnIO driver is not installed.`n`nWithout it, CPU core / package and GPU temperatures cannot be read.`n`nInstall it now with winget (namazso.PawnIO)?",
        'Thermal Monitor', 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        Start-Process winget.exe -Wait -ArgumentList 'install --id namazso.PawnIO -e --accept-source-agreements --accept-package-agreements'
    }
}

# ---------------------------------------------------------------- drawing helpers
function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}

function Draw-CheckBox($g, [single]$x, [single]$y, [single]$size, [bool]$checked) {
    $g.SmoothingMode = 'AntiAlias'
    $path = New-RoundRect $x $y $size $size ([single](Px 3))
    if ($checked) {
        $b = New-Object System.Drawing.SolidBrush($Theme.Accent); $g.FillPath($b, $path); $b.Dispose()
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single](Px 1.6))
        $pts = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF(($x + $size * 0.24), ($y + $size * 0.52))),
            (New-Object System.Drawing.PointF(($x + $size * 0.43), ($y + $size * 0.71))),
            (New-Object System.Drawing.PointF(($x + $size * 0.78), ($y + $size * 0.31))))
        $g.DrawLines($pen, $pts); $pen.Dispose()
    } else {
        $b = New-Object System.Drawing.SolidBrush($Theme.Input); $g.FillPath($b, $path); $b.Dispose()
        $pen = New-Object System.Drawing.Pen($Theme.InputBorder); $g.DrawPath($pen, $path); $pen.Dispose()
    }
    $path.Dispose()
}

# Chevron pointing 'Down', 'Right' or 'Left'
function Draw-Chevron($g, [single]$cx, [single]$cy, [string]$dir, [single]$size = 3.5) {
    $g.SmoothingMode = 'AntiAlias'
    $s = [single](Px $size)
    $pen = New-Object System.Drawing.Pen($Theme.Text, [single](Px 1.4))
    $P = { param($x, $y) New-Object System.Drawing.PointF([single]$x, [single]$y) }
    switch ($dir) {
        'Down'  { $pts = @((& $P ($cx - $s) ($cy - $s / 2)), (& $P $cx ($cy + $s / 2)), (& $P ($cx + $s) ($cy - $s / 2))) }
        'Right' { $pts = @((& $P ($cx - $s / 2) ($cy - $s)), (& $P ($cx + $s / 2) $cy), (& $P ($cx - $s / 2) ($cy + $s))) }
        'Left'  { $pts = @((& $P ($cx + $s / 2) ($cy - $s)), (& $P ($cx - $s / 2) $cy), (& $P ($cx + $s / 2) ($cy + $s))) }
    }
    $g.DrawLines($pen, [System.Drawing.PointF[]]$pts); $pen.Dispose()
}

function Draw-Text($g, [string]$text, $font, $color, [System.Drawing.Rectangle]$rect, [string]$align = 'Left') {
    $f = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    if ($align -eq 'Right') { $f = $f -bor [System.Windows.Forms.TextFormatFlags]::Right }
    if ($align -eq 'Center') { $f = $f -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter }
    [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $font, $rect, $color, $f)
}

function Get-TempColor([double]$v) {
    if ($v -ge $config.HotC) { return $Theme.Hot }
    if ($v -ge $config.WarnC) { return $Theme.Warn }
    $Theme.Good
}

# ---------------------------------------------------------------- reusable controls
function New-Button([string]$text, [switch]$Primary) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.AutoSize = $true; $b.FlatStyle = 'Flat'; $b.Font = $UiFont
    $b.BackColor = $Theme.Input; $b.ForeColor = $Theme.Text
    $b.FlatAppearance.BorderColor = $Theme.InputBorder
    $b.FlatAppearance.MouseOverBackColor = $Theme.ButtonHover
    $b.FlatAppearance.MouseDownBackColor = $Theme.Border
    if ($Primary) {
        $b.BackColor = $Theme.Accent; $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderColor = $Theme.Accent
        $b.FlatAppearance.MouseOverBackColor = $Theme.AccentHover; $b.FlatAppearance.MouseDownBackColor = $Theme.AccentHover
    }
    $b.MinimumSize = New-Object System.Drawing.Size(0, (Px 26)); $b.Height = Px 26
    $b.Padding = New-Object System.Windows.Forms.Padding((Px 6), 0, (Px 6), 0)
    $b.Margin = New-Object System.Windows.Forms.Padding((Px 4), (Px 1), 0, 0)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b
}
function New-Caption([string]$text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.ForeColor = $Theme.Muted; $l.Font = $UiFont
    $l.Margin = New-Object System.Windows.Forms.Padding((Px 14), (Px 6), (Px 6), 0)
    $l
}
# VS Code style checkbox + text. Tag.Checked holds the state; OnChange gets the new value.
function New-CheckToggle([string]$text, [bool]$checked, [scriptblock]$onChange) {
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $false; $l.Cursor = [System.Windows.Forms.Cursors]::Hand
    $l.Size = New-Object System.Drawing.Size(([System.Windows.Forms.TextRenderer]::MeasureText($text, $UiFont).Width + (Px 26)), (Px 26))
    $l.Margin = New-Object System.Windows.Forms.Padding((Px 14), (Px 1), (Px 2), 0)
    $l.Tag = @{ Text = $text; Checked = $checked; OnChange = $onChange }
    $l.Add_Paint({
        param($s, $e)
        $sz = [single](Px 14)
        Draw-CheckBox $e.Graphics 0 ([single](($s.Height - $sz) / 2)) $sz $s.Tag.Checked
        Draw-Text $e.Graphics $s.Tag.Text $UiFont $Theme.Text (New-Object System.Drawing.Rectangle((Px 22), 0, ($s.Width - (Px 22)), $s.Height))
    })
    $l.Add_Click({ $this.Tag.Checked = -not $this.Tag.Checked; $this.Invalidate(); if ($this.Tag.OnChange) { & $this.Tag.OnChange $this.Tag.Checked } })
    $l
}
function Set-Toggle($toggle, [bool]$checked) { $toggle.Tag.Checked = $checked; $toggle.Invalidate() }

function Format-Step([int]$v, [string]$unit) {
    if ($unit -eq 's')   { if ($v -ge 60 -and $v % 60 -eq 0) { return "$($v / 60) min" } else { return "$v s" } }
    if ($v -ge 60 -and $v % 60 -eq 0) { return "$($v / 60) h" }
    "$v min"
}
# [ - ]  5 s  [ + ]   - steps through preset values (the current value is always included)
function New-Stepper([int[]]$presets, [int]$current, [string]$unit, [scriptblock]$onChange) {
    $vals = @(($presets + $current) | Sort-Object -Unique)
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.AutoSize = $true; $p.WrapContents = $false; $p.BackColor = $Theme.Side
    $p.Margin = New-Object System.Windows.Forms.Padding(0, (Px 1), 0, 0)
    $minus = New-Button ([string][char]0x2212); $plus = New-Button '+'
    foreach ($b in $minus, $plus) { $b.AutoSize = $false; $b.Size = New-Object System.Drawing.Size((Px 26), (Px 26)); $b.Padding = New-Object System.Windows.Forms.Padding(0); $b.Margin = New-Object System.Windows.Forms.Padding(0) }
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize = $false; $lbl.Size = New-Object System.Drawing.Size((Px 62), (Px 26)); $lbl.TextAlign = 'MiddleCenter'
    $lbl.BackColor = $Theme.Input; $lbl.ForeColor = $Theme.Text; $lbl.Font = $UiFont
    $lbl.Margin = New-Object System.Windows.Forms.Padding(0)
    $lbl.Text = Format-Step $current $unit
    $p.Tag = @{ Values = $vals; Index = [array]::IndexOf($vals, $current); Label = $lbl; Unit = $unit; OnChange = $onChange }
    $minus.Add_Click({ $st = $this.Parent.Tag; if ($st.Index -gt 0) { $st.Index--; $st.Label.Text = Format-Step $st.Values[$st.Index] $st.Unit; & $st.OnChange $st.Values[$st.Index] } })
    $plus.Add_Click({  $st = $this.Parent.Tag; if ($st.Index -lt $st.Values.Count - 1) { $st.Index++; $st.Label.Text = Format-Step $st.Values[$st.Index] $st.Unit; & $st.OnChange $st.Values[$st.Index] } })
    $p.Controls.AddRange(@($minus, $lbl, $plus))
    $p
}
function Set-StepperValue($stepper, [int]$v) {
    $st = $stepper.Tag
    if ([array]::IndexOf($st.Values, $v) -lt 0) { $st.Values = @(($st.Values + $v) | Sort-Object -Unique) }
    $st.Index = [array]::IndexOf($st.Values, $v)
    $st.Label.Text = Format-Step $v $st.Unit
}

# ---------------------------------------------------------------- window
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Thermal Monitor'
$form.Size = New-Object System.Drawing.Size((Px 1240), (Px 760))
$form.MinimumSize = New-Object System.Drawing.Size((Px 820), (Px 480))
$form.StartPosition = 'CenterScreen'
$form.Font = $UiFont; $form.BackColor = $Theme.Editor; $form.ForeColor = $Theme.Text
$form.Add_HandleCreated({ Set-DarkTitleBar $form })
$tips = New-Object System.Windows.Forms.ToolTip

# toolbar
$bar = New-Object System.Windows.Forms.FlowLayoutPanel
$bar.Dock = 'Top'; $bar.AutoSize = $true; $bar.WrapContents = $true
$bar.Padding = New-Object System.Windows.Forms.Padding((Px 8), (Px 7), (Px 8), (Px 8))
$bar.BackColor = $Theme.Side
$bar.Add_Paint({ param($s, $e) $p = New-Object System.Drawing.Pen($Theme.Border); $e.Graphics.DrawLine($p, 0, $bar.Height - 1, $bar.Width, $bar.Height - 1); $p.Dispose() })

# sensor-list toggle: just an arrow
$btnSensors = New-Button ''
$btnSensors.AutoSize = $false; $btnSensors.Size = New-Object System.Drawing.Size((Px 26), (Px 26))
$btnSensors.Margin = New-Object System.Windows.Forms.Padding(0, (Px 1), 0, 0)
$btnSensors.Add_Paint({
    param($s, $e)
    $dir = if ($split.Panel1Collapsed) { 'Right' } else { 'Left' }
    Draw-Chevron $e.Graphics ([single]($s.Width / 2)) ([single]($s.Height / 2)) $dir 4
})

$stepInterval = New-Stepper @(1, 2, 3, 5, 10, 15, 30, 60, 120, 300) $config.IntervalSeconds 's' {
    param($v) $config.IntervalSeconds = $v; $timer.Interval = $v * 1000; Save-ThermalConfig $AppRoot $config
}
$stepHistory = New-Stepper @(5, 10, 15, 30, 60, 120, 240, 480, 720, 1440) $config.HistoryMinutes 'min' {
    param($v) $config.HistoryMinutes = $v; Save-ThermalConfig $AppRoot $config; Reset-GraphFromLog
}
$tglAvg = New-CheckToggle 'Average' $config.AverageEnabled {
    param($on) $config.AverageEnabled = $on; Save-ThermalConfig $AppRoot $config; Render-AllSeries; Update-StatusExtras
}
$stepAvg = New-Stepper @(10, 15, 30, 60, 120, 300, 600) $config.AverageSeconds 's' {
    param($v) $config.AverageSeconds = $v; Save-ThermalConfig $AppRoot $config; if ($config.AverageEnabled) { Render-AllSeries }; Update-StatusExtras
}
$stepAvg.Margin = New-Object System.Windows.Forms.Padding(0, (Px 1), 0, 0)
$tglLog = New-CheckToggle 'Log to CSV' $config.LogToCsv {
    param($on) $config.LogToCsv = $on; Save-ThermalConfig $AppRoot $config
}

$btnPause    = New-Button 'Pause'
$btnNow      = New-Button 'Read now'
$btnFolder   = New-Button 'Open log folder'
$btnSettings = New-Button 'Settings'

$bar.Controls.AddRange(@(
    $btnSensors,
    (New-Caption 'Interval'), $stepInterval,
    (New-Caption 'History'),  $stepHistory,
    $tglAvg, $stepAvg,
    $tglLog, $btnPause, $btnNow, $btnFolder, $btnSettings))
$tips.SetToolTip($tglAvg, 'Show every line as a moving average over the chosen window')
$tips.SetToolTip($stepAvg, 'Moving-average window')

# status bar
$strip = New-Object System.Windows.Forms.Panel
$strip.Dock = 'Bottom'; $strip.Height = Px 24; $strip.BackColor = $Theme.Side
$strip.Padding = New-Object System.Windows.Forms.Padding((Px 10), 0, (Px 10), 0)
$strip.Add_Paint({ param($s, $e) $p = New-Object System.Drawing.Pen($Theme.Border); $e.Graphics.DrawLine($p, 0, 0, $strip.Width, 0); $p.Dispose() })
$status = New-Object System.Windows.Forms.Label
$status.Dock = 'Fill'; $status.TextAlign = 'MiddleLeft'; $status.Text = 'Starting...'; $status.ForeColor = $Theme.Text
$statusRight = New-Object System.Windows.Forms.Label
$statusRight.Dock = 'Right'; $statusRight.AutoSize = $true; $statusRight.ForeColor = $Theme.Muted
$statusRight.Padding = New-Object System.Windows.Forms.Padding(0, (Px 5), 0, 0)
$strip.Controls.Add($status); $strip.Controls.Add($statusRight)

# split: sensor list | graph
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Vertical'; $split.FixedPanel = 'Panel1'
$split.BackColor = $Theme.Border; $split.SplitterWidth = [math]::Max(1, (Px 1))
$split.Panel1.BackColor = $Theme.Side; $split.Panel2.BackColor = $Theme.Editor

$side = New-Object System.Windows.Forms.Panel
$side.Dock = 'Top'; $side.Height = Px 34; $side.BackColor = $Theme.Side
$side.Add_Paint({ param($s, $e) Draw-Text $e.Graphics 'SENSORS' $HeaderFont $Theme.Text (New-Object System.Drawing.Rectangle((Px 14), 0, (Px 160), $side.Height)) })

# ---------------------------------------------------------------- sensor list (custom-drawn)
# A double-buffered control painted entirely by us: rows, sticky column header and a VS Code style
# scrollbar all follow the theme, and only rows whose values changed are repainted.
$lv = New-Object System.Windows.Forms.UserControl
$lv.Dock = 'Fill'; $lv.BackColor = $Theme.Side; $lv.ForeColor = $Theme.Text; $lv.Font = $UiFont
[System.Windows.Forms.Control].GetMethod('SetStyle', [Reflection.BindingFlags]'NonPublic,Instance').Invoke($lv,
    @([System.Windows.Forms.ControlStyles]'AllPaintingInWmPaint, UserPaint, OptimizedDoubleBuffer, ResizeRedraw, Selectable', $true))

$RowH = Px 24; $HeadH = Px 26; $SbW = Px 10
$ColNow = Px 72; $ColMin = Px 50; $ColMax = Px 58

$script:groupOrder = @('CPU', 'GPU', 'Storage', 'Power & load', 'Battery', 'Lenovo', 'ACPI thermal zones', 'Other')
$script:unit = @{}                  # sensor name -> unit (°C, W, %, GHz)
$script:groupItems = @{}            # group -> sensor names
$script:collapsed  = New-Object System.Collections.Generic.HashSet[string]
foreach ($g in $config.CollapsedGroups) { [void]$script:collapsed.Add($g) }
$script:plot       = New-Object System.Collections.Generic.HashSet[string]
foreach ($n in $config.ChartSensors) { [void]$script:plot.Add($n) }
$script:cur  = @{}; $script:minV = @{}; $script:maxV = @{}
$script:drawn = @{}                 # name -> text last painted, to repaint only rows that changed
$script:listDirty = $false
$script:rows = New-Object System.Collections.Generic.List[object]   # @{ Kind = 'G' | 'S'; Name }
$script:rowIndex = @{}              # sensor name -> row number
$script:scrollY  = 0
$script:hoverRow = -1
$script:sbHover  = $false; $script:sbDrag = $null; $script:sbConsumed = $false

function Get-GroupName([string]$name) {
    if ($name -match '^(CPU|GPU) (Power|Load|Clock)') { return 'Power & load' }
    switch -Regex ($name) {
        '^CPU' { 'CPU' }  '^GPU' { 'GPU' }  '^SSD' { 'Storage' }  '^Battery' { 'Battery' }
        '^Lenovo' { 'Lenovo' }  '^ACPI' { 'ACPI thermal zones' }  default { 'Other' }
    }
}

function Get-Unit([string]$name) { if ($script:unit.ContainsKey($name)) { $script:unit[$name] } else { "$Deg`C" } }
function Test-IsTemp([string]$name) { (Get-Unit $name) -eq "$Deg`C" }
# "49.2" for temperatures, "12.3 W" / "35 %" / "2.41 GHz" for the rest; -WithUnit always adds the unit
function Format-Value([string]$name, [double]$v, [switch]$WithUnit) {
    $u = Get-Unit $name
    $txt = switch ($u) { 'GHz' { $v.ToString('0.00', $Inv) } '%' { $v.ToString('0', $Inv) } default { $v.ToString('0.0', $Inv) } }
    if ($WithUnit -or $u -ne "$Deg`C") { "$txt $u" } else { $txt }
}
function Split-ColumnName([string]$col) {
    # "CPU Power (W)" -> name "CPU Power", unit "W"
    if ($col -match '^(.*) \(([^)]*)\)$') { return @($Matches[1], $Matches[2]) }
    @($col, "$Deg`C")
}

# --- geometry
function Get-ContentHeight { $script:rows.Count * $RowH }
function Get-ViewHeight { [math]::Max(0, $lv.ClientSize.Height - $HeadH) }
function Test-Scrollbar { (Get-ContentHeight) -gt (Get-ViewHeight) }
function Set-Scroll([int]$y) {
    $max = [math]::Max(0, (Get-ContentHeight) - (Get-ViewHeight))
    $y = [math]::Min($max, [math]::Max(0, $y))
    if ($y -ne $script:scrollY) { $script:scrollY = $y; $lv.Invalidate() }
}
function Get-ThumbRect {
    $vh = Get-ViewHeight; $ch = Get-ContentHeight
    if ($ch -le $vh -or $vh -le 0) { return $null }
    $th = [math]::Max((Px 24), [int]($vh * $vh / $ch))
    $ty = $HeadH + [int](($vh - $th) * $script:scrollY / ($ch - $vh))
    New-Object System.Drawing.Rectangle(($lv.ClientSize.Width - $SbW), $ty, $SbW, $th)
}
function Get-RowRect([int]$i) { New-Object System.Drawing.Rectangle(0, ($HeadH + $i * $RowH - $script:scrollY), $lv.ClientSize.Width, $RowH) }
function Get-RowAt([int]$y) {
    if ($y -lt $HeadH) { return -1 }
    $i = [int][math]::Floor(($y - $HeadH + $script:scrollY) / $RowH)
    if ($i -ge 0 -and $i -lt $script:rows.Count) { $i } else { -1 }
}
function Invalidate-Row([int]$i) {
    if ($i -lt 0 -or $i -ge $script:rows.Count) { return }
    $r = Get-RowRect $i
    if ($r.Bottom -gt $HeadH -and $r.Top -lt $lv.ClientSize.Height) { $lv.Invalidate($r) }
}

function Rebuild-List {
    $script:rows.Clear(); $script:rowIndex = @{}
    foreach ($g in $script:groupOrder) {
        if (-not $script:groupItems.ContainsKey($g)) { continue }
        $script:rows.Add(@{ Kind = 'G'; Name = $g })
        if ($script:collapsed.Contains($g)) { continue }
        foreach ($n in $script:groupItems[$g]) { $script:rowIndex[$n] = $script:rows.Count; $script:rows.Add(@{ Kind = 'S'; Name = $n }) }
    }
    $script:listDirty = $false
    $script:drawn = @{}
    $script:hoverRow = -1
    Set-Scroll $script:scrollY
    $lv.Invalidate()
}

function Get-RowText([string]$n) {
    if (-not $script:cur.ContainsKey($n)) { return '' }
    (Format-Value $n $script:cur[$n]) + '|' + (Format-Value $n $script:minV[$n]) + '|' + (Format-Value $n $script:maxV[$n])
}

# Repaint only the rows whose numbers changed (full rebuild only when new sensors appear).
function Refresh-List([string[]]$names) {
    if ($script:listDirty) { Rebuild-List; return }
    foreach ($n in $names) {
        $txt = Get-RowText $n
        if ($script:drawn[$n] -eq $txt) { continue }
        $script:drawn[$n] = $txt
        if ($script:rowIndex.ContainsKey($n)) { Invalidate-Row $script:rowIndex[$n] }
    }
}

# --- painting
$lv.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $w = $lv.ClientSize.Width; $h = $lv.ClientSize.Height
    $sb = Test-Scrollbar
    $right = if ($sb) { $w - $SbW } else { $w }
    $xMax = $right - $ColMax; $xMin = $xMax - $ColMin; $xNow = $xMin - $ColNow
    $clip = $e.ClipRectangle
    $bg = New-Object System.Drawing.SolidBrush($Theme.Side); $g.FillRectangle($bg, $clip); $bg.Dispose()

    # rows (under the sticky header)
    $g.SetClip((New-Object System.Drawing.Rectangle(0, $HeadH, $w, ($h - $HeadH))), [System.Drawing.Drawing2D.CombineMode]::Intersect)
    $first = [math]::Max(0, [int][math]::Floor(($clip.Top - $HeadH + $script:scrollY) / $RowH))
    $last  = [math]::Min($script:rows.Count - 1, [int][math]::Floor(($clip.Bottom - $HeadH + $script:scrollY) / $RowH))
    for ($i = $first; $i -le $last; $i++) {
        $row = $script:rows[$i]
        $y = $HeadH + $i * $RowH - $script:scrollY
        if ($i -eq $script:hoverRow) {
            $hb = New-Object System.Drawing.SolidBrush($Theme.ListHover); $g.FillRectangle($hb, 0, $y, $right, $RowH); $hb.Dispose()
        }
        if ($row.Kind -eq 'G') {
            $grp = $row.Name
            Draw-Chevron $g ([single](Px 14)) ([single]($y + $RowH / 2)) $(if ($script:collapsed.Contains($grp)) { 'Right' } else { 'Down' })
            $count = if ($script:groupItems.ContainsKey($grp)) { @($script:groupItems[$grp]).Count } else { 0 }
            Draw-Text $g $grp.ToUpper() $HeaderFont $Theme.Text (New-Object System.Drawing.Rectangle((Px 24), $y, ($right - (Px 32)), $RowH))
            Draw-Text $g "$count" $UiFont $Theme.Muted (New-Object System.Drawing.Rectangle(0, $y, ($right - (Px 8)), $RowH)) 'Right'
            continue
        }
        $name = $row.Name
        $sz = [single](Px 14); $cx = [single](Px 26)
        Draw-CheckBox $g $cx ([single]($y + ($RowH - $sz) / 2)) $sz ($script:plot.Contains($name))
        Draw-Text $g $name $UiFont $Theme.Text (New-Object System.Drawing.Rectangle(([int]$cx + (Px 22)), $y, [math]::Max(0, $xNow - [int]$cx - (Px 24)), $RowH))
        if ($script:cur.ContainsKey($name)) {
            $v = [double]$script:cur[$name]
            $c = if (Test-IsTemp $name) { Get-TempColor $v } else { $Theme.Text }   # only temperatures are coloured
            Draw-Text $g (Format-Value $name $v) $UiFontBold $c (New-Object System.Drawing.Rectangle($xNow, $y, ($ColNow - (Px 8)), $RowH)) 'Right'
            Draw-Text $g ((Format-Value $name $script:minV[$name]) -replace ' .*$', '') $UiFont $Theme.Muted (New-Object System.Drawing.Rectangle($xMin, $y, ($ColMin - (Px 8)), $RowH)) 'Right'
            Draw-Text $g ((Format-Value $name $script:maxV[$name]) -replace ' .*$', '') $UiFont $Theme.Muted (New-Object System.Drawing.Rectangle($xMax, $y, ($ColMax - (Px 8)), $RowH)) 'Right'
        }
    }
    $g.ResetClip()

    # sticky column header
    if ($clip.Top -lt $HeadH) {
        $hb = New-Object System.Drawing.SolidBrush($Theme.Side); $g.FillRectangle($hb, 0, 0, $w, $HeadH); $hb.Dispose()
        $p = New-Object System.Drawing.Pen($Theme.Border); $g.DrawLine($p, 0, $HeadH - 1, $w, $HeadH - 1); $p.Dispose()
        Draw-Text $g 'Now' $UiFont $Theme.Muted (New-Object System.Drawing.Rectangle($xNow, 0, ($ColNow - (Px 8)), $HeadH)) 'Right'
        Draw-Text $g 'Min' $UiFont $Theme.Muted (New-Object System.Drawing.Rectangle($xMin, 0, ($ColMin - (Px 8)), $HeadH)) 'Right'
        Draw-Text $g 'Max' $UiFont $Theme.Muted (New-Object System.Drawing.Rectangle($xMax, 0, ($ColMax - (Px 8)), $HeadH)) 'Right'
    }

    # VS Code style scrollbar: translucent thumb, brighter on hover / drag
    if ($sb) {
        $t = Get-ThumbRect
        $alpha = if ($script:sbDrag -or $script:sbHover) { 170 } else { 100 }
        $tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 121, 121, 121))
        $g.FillRectangle($tb, ($t.X + (Px 2)), $t.Y, ($t.Width - (Px 3)), $t.Height); $tb.Dispose()
    }
})

# --- mouse
$lv.Add_MouseEnter({ [void]$lv.Focus() })     # so the mouse wheel scrolls the list
$lv.Add_MouseWheel({ param($s, $e) Set-Scroll ($script:scrollY - [int]($e.Delta / 120 * $RowH * 3)) })
$lv.Add_Resize({ Set-Scroll $script:scrollY })
$lv.Add_MouseDown({
    param($s, $e)
    $script:sbConsumed = $false
    $t = Get-ThumbRect
    if ($t -and $e.X -ge $lv.ClientSize.Width - $SbW) {
        $script:sbConsumed = $true
        if ($t.Contains($e.Location)) { $script:sbDrag = @{ Y0 = $e.Y; S0 = $script:scrollY } }
        elseif ($e.Y -lt $t.Top) { Set-Scroll ($script:scrollY - (Get-ViewHeight)) }
        else { Set-Scroll ($script:scrollY + (Get-ViewHeight)) }
        $lv.Invalidate()
    }
})
$lv.Add_MouseUp({ if ($script:sbDrag) { $script:sbDrag = $null; $lv.Invalidate() } })
$lv.Add_MouseMove({
    param($s, $e)
    if ($script:sbDrag) {
        $t = Get-ThumbRect
        if ($t) {
            $ratio = ((Get-ContentHeight) - (Get-ViewHeight)) / [math]::Max(1, (Get-ViewHeight) - $t.Height)
            Set-Scroll ($script:sbDrag.S0 + [int](($e.Y - $script:sbDrag.Y0) * $ratio))
        }
        return
    }
    $onSb = (Test-Scrollbar) -and $e.X -ge $lv.ClientSize.Width - $SbW
    if ($onSb -ne $script:sbHover) {
        $script:sbHover = $onSb
        $lv.Invalidate((New-Object System.Drawing.Rectangle(($lv.ClientSize.Width - $SbW), 0, $SbW, $lv.ClientSize.Height)))
    }
    $idx = if ($onSb) { -1 } else { Get-RowAt $e.Y }
    if ($idx -ne $script:hoverRow) {
        $old = $script:hoverRow; $script:hoverRow = $idx
        Invalidate-Row $old; Invalidate-Row $idx            # only the two rows involved
    }
    $lv.Cursor = if ($idx -ge 0) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
})
$lv.Add_MouseLeave({
    $old = $script:hoverRow; $script:hoverRow = -1; Invalidate-Row $old
    if ($script:sbHover) { $script:sbHover = $false; $lv.Invalidate() }
})
$lv.Add_MouseClick({
    param($s, $e)
    if ($script:sbConsumed -or $e.Button -ne 'Left') { return }
    $i = Get-RowAt $e.Y
    if ($i -lt 0) { return }
    $row = $script:rows[$i]
    if ($row.Kind -eq 'G') {
        $g = $row.Name
        if (-not $script:collapsed.Remove($g)) { [void]$script:collapsed.Add($g) }
        $config.CollapsedGroups = @($script:collapsed)
        Save-ThermalConfig $AppRoot $config
        Rebuild-List
    } else {
        $n = $row.Name
        if (-not $script:plot.Remove($n)) { [void]$script:plot.Add($n) }
        $ser = $chart.Series.FindByName($n)
        if ($ser) {
            $ser.Enabled = $script:plot.Contains($n); $ser.IsVisibleInLegend = $ser.Enabled
            Render-Series $n                                  # draw it (or clear it) from stored readings
            Update-AreaLayout
            $area.RecalculateAxesScale(); $perf.RecalculateAxesScale(); $chart.Invalidate()
        }
        $config.ChartSensors = @($script:plot)
        Save-ThermalConfig $AppRoot $config
        Invalidate-Row $i
    }
})

$split.Panel1.Controls.Add($lv)
$split.Panel1.Controls.Add($side)

# ---------------------------------------------------------------- chart
$chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
$chart.Dock = 'Fill'; $chart.BackColor = $Theme.Editor
$chart.Palette = 'None'
$area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea 'main'
$area.BackColor = $Theme.Editor
foreach ($ax in @($area.AxisX, $area.AxisY)) {
    $ax.LineColor = $Theme.Border; $ax.MajorGrid.LineColor = $Theme.Border; $ax.MajorTickMark.LineColor = $Theme.Border
    $ax.LabelStyle.ForeColor = $Theme.Muted; $ax.LabelStyle.Font = $UiFont
    $ax.TitleForeColor = $Theme.Muted; $ax.TitleFont = $UiFont
}
$area.AxisX.LabelStyle.Format = 'HH:mm:ss'
$area.AxisX.IntervalAutoMode = 'VariableCount'
$area.AxisY.Title = "$Deg`C"
$area.AxisY.IsStartedFromZero = $false
foreach ($lim in @(@{ V = $config.WarnC; C = $Theme.Warn; T = 'warm' }, @{ V = $config.HotC; C = $Theme.Hot; T = 'hot' })) {
    $sl = New-Object System.Windows.Forms.DataVisualization.Charting.StripLine
    $sl.IntervalOffset = $lim.V; $sl.StripWidth = 0; $sl.BorderColor = $lim.C
    $sl.BorderWidth = 1; $sl.BorderDashStyle = 'Dash'; $sl.Text = $lim.T; $sl.ForeColor = $lim.C; $sl.Font = $UiFont
    $area.AxisY.StripLines.Add($sl)
}
$chart.ChartAreas.Add($area)

# Second panel under the temperatures: power (W) and load (%) on the left axis, clocks (GHz) on the right.
$perf = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea 'perf'
$perf.BackColor = $Theme.Editor
foreach ($ax in @($perf.AxisX, $perf.AxisY, $perf.AxisY2)) {
    $ax.LineColor = $Theme.Border; $ax.MajorGrid.LineColor = $Theme.Border; $ax.MajorTickMark.LineColor = $Theme.Border
    $ax.LabelStyle.ForeColor = $Theme.Muted; $ax.LabelStyle.Font = $UiFont
    $ax.TitleForeColor = $Theme.Muted; $ax.TitleFont = $UiFont
}
$perf.AxisX.LabelStyle.Format = 'HH:mm:ss'
$perf.AxisX.IntervalAutoMode = 'VariableCount'
$perf.AxisY.Title = 'W  /  %'
$perf.AxisY.Minimum = 0
$perf.AxisY2.Title = 'GHz'
$perf.AxisY2.Enabled = 'True'
$perf.AxisY2.MajorGrid.Enabled = $false
$perf.AxisY2.Minimum = 0
$perf.AlignWithChartArea = 'main'                 # same plot width / time axis as the temperature panel
$perf.AlignmentOrientation = 'Vertical'
$perf.AlignmentStyle = 'PlotPosition'
$perf.Visible = $false
$chart.ChartAreas.Add($perf)

# One legend per panel, placed directly under it: temperatures under the top graph,
# power / load / clock under the bottom one.
$legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend 'legend'
$perfLegend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend 'perfLegend'
foreach ($lg in $legend, $perfLegend) {
    $lg.Font = $UiFont; $lg.BackColor = $Theme.Editor; $lg.ForeColor = $Theme.Text
    $lg.Position.Auto = $false
    $chart.Legends.Add($lg)
}

function New-ChartPos($y, $h) { New-Object System.Windows.Forms.DataVisualization.Charting.ElementPosition(0, $y, 100, $h) }

# Show the lower panel only when a power / load / clock line is ticked.
# Cheap to call often: it only re-lays out the chart when the panel has to appear or disappear.
$script:layoutPerfOn = $null
function Update-AreaLayout {
    $perfOn = [bool]($chart.Series | Where-Object { $_.Enabled -and $_.ChartArea -eq 'perf' } | Select-Object -First 1)
    $ghzOn  = [bool]($chart.Series | Where-Object { $_.Enabled -and $_.YAxisType -eq 'Secondary' } | Select-Object -First 1)
    $perf.AxisY2.Enabled = if ($ghzOn) { 'True' } else { 'False' }      # right-hand GHz axis only when a clock line is shown
    if ($perfOn -eq $script:layoutPerfOn) { return }
    $script:layoutPerfOn = $perfOn
    $area.Position.Auto = $false; $perf.Position.Auto = $false
    if ($perfOn) {
        $area.Position       = New-ChartPos 0  56
        $legend.Position     = New-ChartPos 56 6
        $perf.Position       = New-ChartPos 62 31
        $perfLegend.Position = New-ChartPos 93 7
        $perf.Visible = $true; $perfLegend.Enabled = $true
    } else {
        $area.Position   = New-ChartPos 0  92
        $legend.Position = New-ChartPos 92 8
        $perf.Visible = $false; $perfLegend.Enabled = $false
    }
}
Update-AreaLayout
$split.Panel2.Controls.Add($chart)
$split.Panel2.Padding = New-Object System.Windows.Forms.Padding((Px 6), (Px 10), (Px 12), (Px 4))

$form.Controls.Add($split)
$form.Controls.Add($strip)
$form.Controls.Add($bar)
$split.SplitterDistance = Px 340
$split.Panel1Collapsed = $config.SensorsCollapsed

# ---------------------------------------------------------------- data: raw readings -> displayed lines
# Raw readings are kept per sensor; the graph shows them as-is or as a moving average.
$script:paused  = $false
$script:firstAt = $null
$script:nowX    = (Get-Date).ToOADate()
$script:pending = New-Object System.Collections.ArrayList
$script:rawX = @{}; $script:rawY = @{}       # name -> List[double] (OADate, degrees C)

function Get-GapDays { [math]::Max(30, 3 * $config.IntervalSeconds) / 86400.0 }

function Add-SensorIfNew([string]$name, [string]$unit = "$Deg`C") {
    if ($chart.Series.FindByName($name)) { return }
    $script:unit[$name] = $unit
    $g = Get-GroupName $name
    if (-not $script:groupItems.ContainsKey($g)) { $script:groupItems[$g] = @() }
    $script:groupItems[$g] = @(@($script:groupItems[$g]) + $name | Sort-Object @{ e = { Get-ThermalColumnRank $_ } }, @{ e = { $_ } })
    $script:listDirty = $true
    $script:rawX[$name] = New-Object System.Collections.Generic.List[double]
    $script:rawY[$name] = New-Object System.Collections.Generic.List[double]

    $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series $name
    $s.ChartType = 'Line'; $s.XValueType = 'DateTime'; $s.BorderWidth = 2
    $s.EmptyPointStyle.Color = [System.Drawing.Color]::Transparent   # gaps in the log = no line
    $s.Enabled = $script:plot.Contains($name); $s.IsVisibleInLegend = $s.Enabled
    if ($unit -ne "$Deg`C") {
        $s.ChartArea = 'perf'                                   # power / load / clock panel
        $s.Legend = 'perfLegend'
        if ($unit -eq 'GHz') { $s.YAxisType = 'Secondary' }     # clocks on the right-hand axis
        $s.LegendText = "$name ($unit)"
    } else { $s.Legend = 'legend' }
    $s.Color = Get-LineColor $name                              # fixed colour; the hover box reuses it
    $chart.Series.Add($s)
    # A ticked power/load line that is new this run (not in the loaded history) must open the
    # lower panel; otherwise only its legend entry would show.
    if ($s.Enabled) { Update-AreaLayout }
}

function Add-ChartPoint($series, [double]$x, [double]$y) {
    # If the monitor was not running for a while, break the line instead of joining across the gap.
    if ($series.Points.Count -gt 0) {
        $last = $series.Points[$series.Points.Count - 1]
        if ($x - $last.XValue -gt (Get-GapDays)) {
            $gap = [System.Windows.Forms.DataVisualization.Charting.DataPoint]::new(($last.XValue + $x) / 2, $last.YValues[0])
            $gap.IsEmpty = $true
            $series.Points.Add($gap)
        }
    }
    [void]$series.Points.AddXY($x, $y)
}

function Set-SensorValue([string]$name, [double]$v) {
    $script:cur[$name] = $v
    if (-not $script:minV.ContainsKey($name) -or $v -lt $script:minV[$name]) { $script:minV[$name] = $v }
    if (-not $script:maxV.ContainsKey($name) -or $v -gt $script:maxV[$name]) { $script:maxV[$name] = $v }
}

# Moving average of the last raw reading (stops at gaps in the log)
function Get-AverageAtEnd([string]$name) {
    $xs = $script:rawX[$name]; $ys = $script:rawY[$name]
    $n = $xs.Count; $w = $config.AverageSeconds / 86400.0; $gap = Get-GapDays
    $sum = 0.0; $cnt = 0; $j = $n - 1
    while ($j -ge 0) {
        if ($xs[$j] -lt $xs[$n - 1] - $w) { break }
        if ($j -lt $n - 1 -and $xs[$j + 1] - $xs[$j] -gt $gap) { break }
        $sum += $ys[$j]; $cnt++; $j--
    }
    $sum / [math]::Max(1, $cnt)
}

# Redraw one line from its raw readings (raw or moving average). Hidden lines keep no points.
function Render-Series([string]$name) {
    $s = $chart.Series.FindByName($name)
    if (-not $s) { return }
    $s.Points.SuspendUpdates()
    $s.Points.Clear()
    if ($s.Enabled) {
        $xs = $script:rawX[$name]; $ys = $script:rawY[$name]
        $since = $script:nowX - $config.HistoryMinutes / 1440.0
        $avg = $config.AverageEnabled; $w = $config.AverageSeconds / 86400.0; $gap = Get-GapDays
        $start = 0; $sum = 0.0
        for ($i = 0; $i -lt $xs.Count; $i++) {
            $y = $ys[$i]
            if ($avg) {
                if ($i -gt 0 -and $xs[$i] - $xs[$i - 1] -gt $gap) { $start = $i; $sum = 0.0 }
                $sum += $ys[$i]
                while ($xs[$start] -lt $xs[$i] - $w) { $sum -= $ys[$start]; $start++ }
                $y = $sum / ($i - $start + 1)
            }
            if ($xs[$i] -ge $since) { Add-ChartPoint $s $xs[$i] ([math]::Round($y, 2)) }
        }
    }
    $s.Points.ResumeUpdates()
}

function Render-AllSeries {
    foreach ($s in $chart.Series) { Render-Series $s.Name }
    Update-AreaLayout
    Update-AxisRange ([DateTime]::FromOADate($script:nowX))
}

function Update-AxisRange([datetime]$now) {
    $since = $now.AddMinutes(-$config.HistoryMinutes)
    $from = if ($script:firstAt -and $script:firstAt -gt $since) { $script:firstAt } else { $since }
    foreach ($a in $area, $perf) {
        $a.AxisX.Minimum = $from.ToOADate()
        $a.AxisX.Maximum = [math]::Max($now.ToOADate(), $from.AddSeconds(10).ToOADate())
        $a.RecalculateAxesScale()
    }
}

# Load the last HistoryMinutes (+ averaging window) of readings from the CSV log.
function Import-History {
    $now  = Get-Date
    $script:nowX = $now.ToOADate()
    $from = $now.AddMinutes(-$config.HistoryMinutes).AddSeconds(-$config.AverageSeconds)
    $rows = @(Read-RecentThermalRows $csvPath $from)
    if ($rows.Count -eq 0) { return 0 }
    $cols = Sort-ThermalColumns @($rows | ForEach-Object { $_.Values.Keys } | Select-Object -Unique)
    foreach ($col in $cols) {
        $name, $unit = Split-ColumnName $col
        Add-SensorIfNew $name $unit
        $xs = $script:rawX[$name]; $ys = $script:rawY[$name]
        foreach ($r in $rows) {
            if (-not $r.Values.Contains($col)) { continue }
            $v = [double]$r.Values[$col]
            $xs.Add($r.Time.ToOADate()); $ys.Add($v)
            Set-SensorValue $name $v
        }
    }
    $script:firstAt = $rows[0].Time
    Refresh-List @($script:cur.Keys)
    Render-AllSeries
    $rows.Count
}

# Re-read the graph from the log (when History changes). Every live reading is logged, so nothing on
# screen is lost; when logging is off, just re-draw what is in memory.
function Reset-GraphFromLog {
    if ($config.LogToCsv -and $script:pending.Count -eq 0) {
        foreach ($k in @($script:rawX.Keys)) { $script:rawX[$k].Clear(); $script:rawY[$k].Clear() }
        $script:firstAt = $null
        try { [void](Import-History) } catch { }
    }
    $script:nowX = (Get-Date).ToOADate()
    Render-AllSeries
}

function Save-Pending {
    if (-not $config.LogToCsv -or $script:pending.Count -eq 0) { return $true }
    try { Save-ThermalRows $csvPath $script:pending.ToArray(); $script:pending.Clear(); return $true }
    catch { return $false }
}

$script:baseStatus = ''
function Update-StatusExtras {
    $extra = if ($config.AverageEnabled) { "    Graph: $(Format-Step $config.AverageSeconds 's') moving average" } else { '' }
    $status.Text = $script:baseStatus + $extra
}

function Update-Readings {
    $now   = Get-Date
    $temps = @(Read-AllTemps)
    if ($temps.Count -eq 0) { $status.Text = "$($now.ToString('HH:mm:ss'))  -  no sensors could be read"; return }
    if (-not $script:firstAt) { $script:firstAt = $now }
    $x = $now.ToOADate(); $script:nowX = $x

    $metrics = @(Read-AllMetrics)
    $row  = ConvertTo-ThermalRow $temps $now.ToString('yyyy-MM-dd HH:mm:ss') $metrics
    $cols = Sort-ThermalColumns @($row.Keys | Where-Object { $_ -ne 'Timestamp' })
    $since = $x - $config.HistoryMinutes / 1440.0
    $keepFrom = $since - $config.AverageSeconds / 86400.0

    $names = @(); $hotName = ''; $hotVal = -999; $tempCount = 0
    foreach ($col in $cols) {
        $name, $unit = Split-ColumnName $col
        $v = [double]::Parse($row[$col], $Inv)
        Add-SensorIfNew $name $unit
        Set-SensorValue $name $v
        $names += $name
        if ($unit -eq "$Deg`C") { $tempCount++; if ($v -gt $hotVal) { $hotVal = $v; $hotName = $name } }

        $xs = $script:rawX[$name]; $ys = $script:rawY[$name]
        $xs.Add($x); $ys.Add($v)
        while ($xs.Count -gt 0 -and $xs[0] -lt $keepFrom) { $xs.RemoveAt(0); $ys.RemoveAt(0) }

        $s = $chart.Series.FindByName($name)
        if ($s.Enabled) {
            $y = if ($config.AverageEnabled) { [math]::Round((Get-AverageAtEnd $name), 2) } else { $v }
            Add-ChartPoint $s $x $y
            while ($s.Points.Count -gt 0 -and ($s.Points[0].XValue -lt $since -or $s.Points[0].IsEmpty)) { $s.Points.RemoveAt(0) }
        }
    }
    Refresh-List $names
    Update-AxisRange $now

    $script:baseStatus = "Last read $($now.ToString('HH:mm:ss'))    $tempCount temperature sensors    Hottest: $hotName $($hotVal.ToString('0.0', $Inv)) $Deg`C"
    $pw = $metrics | Where-Object Sensor -eq 'CPU Power' | Select-Object -First 1
    if ($pw) { $script:baseStatus += "    CPU $($pw.Value) W" }
    if (-not ($cols | Where-Object { $_ -match '^GPU' })) { $script:baseStatus += "    GPU temperature not available" }
    Update-StatusExtras

    if ($config.LogToCsv) {
        [void]$script:pending.Add($row)
        if (Save-Pending) { $statusRight.Text = 'Logging to data\thermal_log.csv'; $statusRight.ForeColor = $Theme.Muted }
        else { $statusRight.Text = "CSV locked (open in Excel?) - $($script:pending.Count) reading(s) waiting"; $statusRight.ForeColor = $Theme.Warn }
    } else { $statusRight.Text = 'Not logging'; $statusRight.ForeColor = $Theme.Muted }
}

# ---------------------------------------------------------------- settings window
function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'; $dlg.Font = $UiFont
    $dlg.BackColor = $Theme.Editor; $dlg.ForeColor = $Theme.Text
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false; $dlg.StartPosition = 'CenterParent'
    $dlg.Add_HandleCreated({ param($s, $e) Set-DarkTitleBar $s })
    $W = Px 560; $pad = Px 24; $inputW = Px 96

    $script:set = @{}
    $y = Px 18
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'SETTINGS'; $title.Font = $HeaderFont; $title.ForeColor = $Theme.Text; $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point($pad, $y); $dlg.Controls.Add($title)
    $y += Px 30

    $rows = @(
        @{ Key = 'IntervalSeconds'; Title = 'Read interval';      Desc = 'Seconds between sensor readings (1 - 3600).'; Kind = 'num' },
        @{ Key = 'HistoryMinutes';  Title = 'Graph history';      Desc = 'Minutes on the graph, loaded from the log on start (1 - 1440).'; Kind = 'num' },
        @{ Key = 'AverageEnabled';  Title = 'Moving average';     Desc = 'Show every graph line as an average instead of raw readings.'; Kind = 'bool' },
        @{ Key = 'AverageSeconds';  Title = 'Average window';     Desc = 'Seconds each average covers (5 - 3600).'; Kind = 'num' },
        @{ Key = 'WarnC';           Title = "Warm threshold ($Deg`C)"; Desc = 'Values turn amber from here; dashed line on the graph.'; Kind = 'num' },
        @{ Key = 'HotC';            Title = "Hot threshold ($Deg`C)";  Desc = 'Values turn red from here; dashed line on the graph.'; Kind = 'num' },
        @{ Key = 'LogToCsv';        Title = 'Log to CSV';         Desc = 'Append every reading to data\thermal_log.csv.'; Kind = 'bool' },
        @{ Key = 'AllHardware';     Title = 'Probe all hardware'; Desc = 'Also query motherboard Super I/O, RAM SPD, USB controllers and PSUs. Off is safer. Applies after restart.'; Kind = 'bool' }
    )
    foreach ($r in $rows) {
        $t = New-Object System.Windows.Forms.Label
        $t.Text = $r.Title; $t.Font = $UiFontBold; $t.ForeColor = $Theme.Text; $t.AutoSize = $true
        $t.Location = New-Object System.Drawing.Point($pad, $y)
        $d = New-Object System.Windows.Forms.Label
        $d.Text = $r.Desc; $d.Font = $SmallFont; $d.ForeColor = $Theme.Muted; $d.AutoSize = $false
        $d.Size = New-Object System.Drawing.Size(($W - 2 * $pad - $inputW - (Px 20)), (Px 32))
        $d.Location = New-Object System.Drawing.Point($pad, ($y + (Px 20)))
        $dlg.Controls.AddRange(@($t, $d))
        if ($r.Kind -eq 'num') {
            $c = New-Object System.Windows.Forms.TextBox
            $c.Text = [string]$config[$r.Key]; $c.BackColor = $Theme.Input; $c.ForeColor = $Theme.Text
            $c.BorderStyle = 'FixedSingle'; $c.Font = $UiFont; $c.TextAlign = 'Right'; $c.Width = $inputW
            $c.Location = New-Object System.Drawing.Point(($W - $pad - $inputW), ($y + (Px 8)))
        } else {
            $c = New-CheckToggle 'Enabled' ([bool]$config[$r.Key]) $null
            $c.Location = New-Object System.Drawing.Point(($W - $pad - $inputW), ($y + (Px 6)))
        }
        $dlg.Controls.Add($c)
        $script:set[$r.Key] = $c
        $y += Px 60
    }

    $err = New-Object System.Windows.Forms.Label
    $err.ForeColor = $Theme.Hot; $err.AutoSize = $false; $err.Font = $SmallFont
    $err.Size = New-Object System.Drawing.Size(($W - 2 * $pad - (Px 190)), (Px 34))
    $err.Location = New-Object System.Drawing.Point($pad, ($y + (Px 4)))
    $script:set['_err'] = $err
    $btnSave = New-Button 'Save' -Primary; $btnCancel = New-Button 'Cancel'
    foreach ($b in $btnSave, $btnCancel) { $b.AutoSize = $false; $b.Size = New-Object System.Drawing.Size((Px 80), (Px 28)) }
    $btnSave.Location   = New-Object System.Drawing.Point(($W - $pad - (Px 80)), ($y + (Px 6)))
    $btnCancel.Location = New-Object System.Drawing.Point(($W - $pad - (Px 168)), ($y + (Px 6)))
    $btnCancel.DialogResult = 'Cancel'
    $dlg.CancelButton = $btnCancel
    $dlg.Controls.AddRange(@($err, $btnSave, $btnCancel))
    $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y + (Px 52)))
    $dlg.ActiveControl = $btnSave          # don't open with a field's text selected

    $btnSave.Add_Click({
        $s = $script:set
        $num = @{}
        $bad = @()
        foreach ($k in 'IntervalSeconds', 'HistoryMinutes', 'AverageSeconds', 'WarnC', 'HotC') {
            $v = 0
            if ([int]::TryParse($s[$k].Text.Trim(), [ref]$v)) { $num[$k] = $v } else { $bad += $k }
        }
        if (-not $bad -and ($num.IntervalSeconds -lt 1 -or $num.IntervalSeconds -gt 3600)) { $bad += 'Read interval must be 1 - 3600' }
        if (-not $bad -and ($num.HistoryMinutes -lt 1 -or $num.HistoryMinutes -gt 1440)) { $bad += 'Graph history must be 1 - 1440' }
        if (-not $bad -and ($num.AverageSeconds -lt 5 -or $num.AverageSeconds -gt 3600)) { $bad += 'Average window must be 5 - 3600' }
        if (-not $bad -and ($num.WarnC -ge $num.HotC -or $num.WarnC -lt 20 -or $num.HotC -gt 120)) { $bad += 'Warm must be below Hot (20 - 120)' }
        if ($bad) { $s['_err'].Text = 'Please fix: ' + (($bad | ForEach-Object { $_ -replace '^(IntervalSeconds|HistoryMinutes|AverageSeconds|WarnC|HotC)$', '$1 is not a whole number' }) -join '; '); return }
        Apply-Settings $num $s.AverageEnabled.Tag.Checked $s.LogToCsv.Tag.Checked $s.AllHardware.Tag.Checked
        $this.FindForm().DialogResult = 'OK'
    })
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

function Apply-Settings($num, [bool]$avgOn, [bool]$logOn, [bool]$allHw) {
    $historyChanged = $num.HistoryMinutes -ne $config.HistoryMinutes
    $restart = $allHw -ne $config.AllHardware
    $config.IntervalSeconds = $num.IntervalSeconds
    $config.HistoryMinutes  = $num.HistoryMinutes
    $config.AverageSeconds  = $num.AverageSeconds
    $config.AverageEnabled  = $avgOn
    $config.WarnC = [double]$num.WarnC; $config.HotC = [double]$num.HotC
    $config.LogToCsv = $logOn; $config.AllHardware = $allHw
    Save-ThermalConfig $AppRoot $config

    $timer.Interval = $config.IntervalSeconds * 1000
    Set-StepperValue $stepInterval $config.IntervalSeconds
    Set-StepperValue $stepHistory  $config.HistoryMinutes
    Set-StepperValue $stepAvg      $config.AverageSeconds
    Set-Toggle $tglAvg $avgOn; Set-Toggle $tglLog $logOn
    $area.AxisY.StripLines[0].IntervalOffset = $config.WarnC
    $area.AxisY.StripLines[1].IntervalOffset = $config.HotC
    $script:drawn = @{}; $lv.Invalidate()                     # colours depend on the thresholds
    if ($historyChanged) { Reset-GraphFromLog } else { Render-AllSeries }
    Update-StatusExtras
    if ($restart) { [void][System.Windows.Forms.MessageBox]::Show('"Probe all hardware" applies the next time the window is opened.', 'Thermal Monitor') }
}

# ---------------------------------------------------------------- timer & toolbar events
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $config.IntervalSeconds * 1000
$timer.Add_Tick({
    $timer.Stop()
    try { Update-Readings }
    catch { $status.Text = "Read error: $($_.Exception.Message)" }
    finally { if (-not $script:paused) { $timer.Start() } }
})

$btnSensors.Add_Click({
    $split.Panel1Collapsed = -not $split.Panel1Collapsed
    $config.SensorsCollapsed = $split.Panel1Collapsed
    $tips.SetToolTip($btnSensors, $(if ($split.Panel1Collapsed) { 'Show sensor list' } else { 'Hide sensor list' }))
    $btnSensors.Invalidate()
    Save-ThermalConfig $AppRoot $config
})
$tips.SetToolTip($btnSensors, $(if ($config.SensorsCollapsed) { 'Show sensor list' } else { 'Hide sensor list' }))
$btnPause.Add_Click({
    $script:paused = -not $script:paused
    if ($script:paused) { $timer.Stop(); $btnPause.Text = 'Resume'; $status.Text = 'Paused' }
    else { $btnPause.Text = 'Pause'; $timer.Start() }
})
$btnNow.Add_Click({ try { Update-Readings } catch { $status.Text = "Read error: $($_.Exception.Message)" } })
$btnFolder.Add_Click({ Start-Process explorer.exe "`"$OutDir`"" })
$btnSettings.Add_Click({ Show-SettingsDialog })

# ---------------------------------------------------------------- graph hover: crosshair + value box
$script:hoverX = $null      # mouse position on the time axis (OADate), $null = not hovering
$script:hoverY = 0

$script:hoverArea = 'main'  # panel the mouse is over (the value box is drawn there)

function Get-PlotRect($a) {
    $ap = $a.Position; $ip = $a.InnerPlotPosition
    $x = $chart.Width  * ($ap.X + $ap.Width  * $ip.X / 100) / 100
    $y = $chart.Height * ($ap.Y + $ap.Height * $ip.Y / 100) / 100
    $w = $chart.Width  * ($ap.Width  * $ip.Width  / 100) / 100
    $h = $chart.Height * ($ap.Height * $ip.Height / 100) / 100
    New-Object System.Drawing.RectangleF([single]$x, [single]$y, [single]$w, [single]$h)
}

function Get-NearestPoint($series, [double]$x) {
    $best = $null; $bestD = [double]::MaxValue
    foreach ($p in $series.Points) { if ($p.IsEmpty) { continue }; $d = [math]::Abs($p.XValue - $x); if ($d -lt $bestD) { $bestD = $d; $best = $p } }
    $best
}

function Get-SeriesPixelY($s, [double]$v) {
    $a = if ($s.ChartArea -eq 'perf') { $perf } else { $area }
    if ([string]$s.YAxisType -eq 'Secondary') { $a.AxisY2.ValueToPixelPosition($v) } else { $a.AxisY.ValueToPixelPosition($v) }
}

$chart.Add_MouseMove({
    param($sender, $e)
    try {
        $hit = $null
        foreach ($a in @($area, $perf)) {
            if (-not $a.Visible) { continue }
            $r = Get-PlotRect $a
            if ($e.X -ge $r.Left -and $e.X -le $r.Right -and $e.Y -ge $r.Top -and $e.Y -le $r.Bottom) { $hit = $a; break }
        }
        if (-not $hit) {
            if ($null -ne $script:hoverX) { $script:hoverX = $null; $chart.Invalidate() }
            return
        }
        $script:hoverX = $hit.AxisX.PixelPositionToValue($e.X)
        $script:hoverY = $e.Y
        $script:hoverArea = $hit.Name
        $chart.Invalidate()
    } catch { $script:hoverX = $null }
})
$chart.Add_MouseLeave({ $script:hoverX = $null; $chart.Invalidate() })

$chart.Add_PostPaint({
    param($sender, $e)
    if ($null -eq $script:hoverX -or $e.ChartElement -isnot [System.Windows.Forms.DataVisualization.Charting.ChartArea]) { return }
    $a = $e.ChartElement
    if (-not $a.Visible) { return }
    try {
        $shown = @($chart.Series | Where-Object { $_.Enabled -and $_.Points.Count -gt 0 })
        if ($shown.Count -eq 0) { return }
        $first = Get-NearestPoint $shown[0] $script:hoverX
        if (-not $first) { return }
        $snap = $first.XValue                                   # snap to the nearest reading
        $entries = @(foreach ($s in $shown) {
            $p = Get-NearestPoint $s $snap
            if ($p) { [pscustomobject]@{ Name = $s.Name; Value = $p.YValues[0]; Color = $s.Color; Area = $s.ChartArea; Y = (Get-SeriesPixelY $s $p.YValues[0]) } }
        })

        $g = $e.ChartGraphics.Graphics
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
        $r  = Get-PlotRect $a
        $px = [single]$a.AxisX.ValueToPixelPosition($snap)

        # crosshair + dots in this panel
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, $Theme.Muted), [single](Px 1)); $pen.DashStyle = 'Dash'
        $g.DrawLine($pen, $px, $r.Top, $px, $r.Bottom); $pen.Dispose()
        $rad = [single](Px 4)
        $ring = New-Object System.Drawing.Pen($Theme.Editor, [single](Px 1.5))
        foreach ($en in @($entries | Where-Object Area -eq $a.Name)) {
            $py = [single]$en.Y
            $b = New-Object System.Drawing.SolidBrush($en.Color)
            $g.FillEllipse($b, $px - $rad, $py - $rad, 2 * $rad, 2 * $rad); $g.DrawEllipse($ring, $px - $rad, $py - $rad, 2 * $rad, 2 * $rad)
            $b.Dispose()
        }
        $ring.Dispose()
        # Draw the value box once, while painting the last visible panel, so no panel paints over it.
        $lastPanel = if ($perf.Visible) { 'perf' } else { 'main' }
        if ($a.Name -ne $lastPanel) { return }
        $a = if ($script:hoverArea -eq 'perf' -and $perf.Visible) { $perf } else { $area }
        $px = [single]$a.AxisX.ValueToPixelPosition($snap)

        # value box (VS Code hover widget style): this panel's lines top-to-bottom as on screen, then the other panel's
        $here  = @($entries | Where-Object Area -eq $a.Name | Sort-Object Y)
        $other = @($entries | Where-Object Area -ne $a.Name | Sort-Object Y)
        $title = [DateTime]::FromOADate($snap).ToString('HH:mm:ss')
        if ($config.AverageEnabled) { $title += "   avg $(Format-Step $config.AverageSeconds 's')" }
        $lines = @(@($here) + @($other) | ForEach-Object { [pscustomobject]@{ L = $_.Name; R = (Format-Value $_.Name $_.Value -WithUnit); C = $_.Color } })
        $sepAfter = if ($here.Count -gt 0 -and $other.Count -gt 0) { $here.Count } else { -1 }
        $lineH = [single]([System.Windows.Forms.TextRenderer]::MeasureText('Ag', $UiFont).Height + (Px 2))
        $sw = [single](Px 9); $pad = [single](Px 10); $gap = [single](Px 18)
        $wL = ($lines | ForEach-Object { [System.Windows.Forms.TextRenderer]::MeasureText($_.L, $UiFont).Width } | Measure-Object -Maximum).Maximum
        $wR = ($lines | ForEach-Object { [System.Windows.Forms.TextRenderer]::MeasureText($_.R, $UiFontBold).Width } | Measure-Object -Maximum).Maximum
        $boxW = [single]([math]::Max($sw + (Px 8) + $wL + $gap + $wR, [System.Windows.Forms.TextRenderer]::MeasureText($title, $UiFont).Width) + 2 * $pad)
        $boxH = [single](($lines.Count + 1) * $lineH + 2 * $pad + (Px 4) + $(if ($sepAfter -ge 0) { Px 6 } else { 0 }))
        $r = Get-PlotRect $area; $r2 = Get-PlotRect $perf      # the box may use the whole graph height
        if ($perf.Visible) { $r = [System.Drawing.RectangleF]::Union($r, $r2) }

        $bx = $px + (Px 14)
        if ($bx + $boxW -gt $r.Right) { $bx = $px - (Px 14) - $boxW }
        $by = [single][math]::Min([math]::Max($script:hoverY - $boxH / 2, $r.Top), $r.Bottom - $boxH)

        $path = New-RoundRect $bx $by $boxW $boxH ([single](Px 4))
        $bg = New-Object System.Drawing.SolidBrush($Theme.HoverBg); $g.FillPath($bg, $path); $bg.Dispose()
        $bp = New-Object System.Drawing.Pen($Theme.HoverBorder); $g.DrawPath($bp, $path); $bp.Dispose(); $path.Dispose()

        $tr = New-Object System.Drawing.Rectangle([int]($bx + $pad), [int]($by + $pad), [int]($boxW - 2 * $pad), [int]$lineH)
        Draw-Text $g $title $UiFont $Theme.Muted $tr
        $sep = New-Object System.Drawing.Pen($Theme.HoverBorder)
        $g.DrawLine($sep, $bx + $pad, $by + $pad + $lineH + (Px 2), $bx + $boxW - $pad, $by + $pad + $lineH + (Px 2)); $sep.Dispose()

        $yy = $by + $pad + $lineH + (Px 4)
        $i = 0
        foreach ($ln in $lines) {
            if ($i -eq $sepAfter) {
                $sp = New-Object System.Drawing.Pen($Theme.HoverBorder)
                $g.DrawLine($sp, $bx + $pad, $yy + (Px 3), $bx + $boxW - $pad, $yy + (Px 3)); $sp.Dispose()
                $yy += Px 6
            }
            $i++
            $b = New-Object System.Drawing.SolidBrush($ln.C)
            $g.FillEllipse($b, $bx + $pad, $yy + ($lineH - $sw) / 2, $sw, $sw); $b.Dispose()
            $lr = New-Object System.Drawing.Rectangle([int]($bx + $pad + $sw + (Px 8)), [int]$yy, [int]$wL, [int]$lineH)
            Draw-Text $g $ln.L $UiFont $Theme.Text $lr
            $rr = New-Object System.Drawing.Rectangle([int]($bx + $pad), [int]$yy, [int]($boxW - 2 * $pad), [int]$lineH)
            Draw-Text $g $ln.R $UiFontBold $Theme.Text $rr 'Right'
            $yy += $lineH
        }
    } catch { $script:paintError = "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" }
})

# ---------------------------------------------------------------- start / stop
$form.Add_Shown({
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $status.Text = 'Starting sensors (first run downloads and verifies LibreHardwareMonitor)...'
    $form.Refresh()
    try {
        $loaded = 0
        try { $loaded = Import-History } catch { }   # earlier readings from the log
        Initialize-ThermalCore $AppRoot $ScriptDir $config.AllHardware
        Update-Readings
        if ($loaded -gt 0) { $script:baseStatus += "    Loaded $loaded earlier reading(s) from the log"; Update-StatusExtras }
        $timer.Start()
    } catch {
        Show-Error $_.Exception.Message
        $form.Close()
    } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})

$form.Add_FormClosing({
    $timer.Stop()
    [void](Save-Pending)
    Close-ThermalCore
})

try { [System.Windows.Forms.Application]::Run($form) }
catch { Show-Error $_.Exception.Message }
