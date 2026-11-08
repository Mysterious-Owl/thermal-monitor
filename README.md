# Thermal Monitor

Reads every temperature sensor on a Windows laptop: CPU package and cores, Intel iGPU, NVMe SSD, battery and ACPI zones. It also reads CPU/GPU power, load and clock speed. Everything is logged to a single CSV, and a dark, VS Code-style window shows live graphs.

Built and tested on a Lenovo IdeaPad Slim 5 14IMH9 (Intel Core Ultra 5 125H "Meteor Lake", Intel Arc iGPU). Other laptops should work, but the sensors you get depend on the hardware.

## Features

- **Live window:**
  - A sensor list grouped by hardware, with Now / Min / Max columns. Only rows whose values change are redrawn.
  - Graphs with warm/hot bands, plus a second panel for W / % / GHz.
  - A hover crosshair with a value box listing every line.
- **History on start:** when the window opens, the graph is filled from the last *N* minutes of the log.
- **Moving average:** a toggle with an adjustable window turns every line into a smoothed average.
- **Settings window:** change the interval, history length, average, warn/hot thresholds, logging and extra hardware. No need to edit JSON by hand.
- **Console mode:** a single reading, or a refreshing watch view.
- **iGPU temperature on Meteor Lake:** read directly from the processor's `THERM_STATUS_GT` register through the signed PawnIO driver. Task Manager shows "N/A" on these chips; this uses the same method as LibreHardwareMonitor PR #2551.

## Requirements

- Windows 10/11 with Windows PowerShell 5.1, which is built in.
- **Administrator rights.** The scripts relaunch themselves elevated.
- **[PawnIO](https://pawnio.eu/) driver** for CPU core/package and iGPU temperatures. The console version offers to install it with `winget install namazso.PawnIO`.
- Internet on the first run, to download the libraries into `lib/`.

## Usage

| Launcher | What it does |
|---|---|
| `Start-ThermalMonitor.bat` | Opens the graph window. |
| `Start-ThermalConsole.bat` | Prints one reading. |
| `Start-ThermalConsole.bat watch` | Refreshes in the console until Ctrl+C. |

You can also run the console script directly:

```powershell
.\src\ThermalConsole.ps1 -Watch -Interval 10    # -AllHardware also probes Super I/O, RAM, USB, PSU
```

To use the window:

- Click a sensor in the list to add it to or remove it from the graph.
- Click a group header to collapse it.
- The arrow button at top left hides or shows the list.

## Output

All runs append to **`data/thermal_log.csv`**: one row per reading and one column per sensor, for example:

```
Timestamp, CPU Package (°C), CPU Core Max (°C), ..., GPU Core (°C), SSD Composite (°C), ..., CPU Power (W), CPU Load (%), CPU Clock Avg (GHz)
```

When a new sensor appears, a column is added and older rows get blanks in it. The file is read with shared access, so you can keep it open while logging. If Excel locks it, readings are held in memory and written once the file is free.

## Configuration

`config.json` is created on first run. You can edit it from the window's **Settings** button.

| Key | Default | Meaning |
|---|---|---|
| `IntervalSeconds` | 5 | Time between readings |
| `HistoryMinutes` | 15 | How much time the graph shows and loads from the log |
| `AverageEnabled` / `AverageSeconds` | false / 30 | Moving-average display |
| `WarnC` / `HotC` | 75 / 90 | Colour thresholds (°C) |
| `LogToCsv` | true | Write readings to the CSV |
| `AllHardware` | false | Also probe motherboard, RAM, controllers and PSU |
| `ChartSensors` | CPU Package, CPU Core Max, GPU Core, SSD Composite | Lines shown on start |

## Project layout

```
Start-ThermalMonitor.bat   launches the window (hidden console)
Start-ThermalConsole.bat   launches the console version
src/ThermalCore.ps1        sensor engine: library download/verification, all sensor readers, config
src/ThermalCsv.ps1         wide-CSV writer/reader
src/ThermalUI.ps1          WinForms window, graphs, settings dialog
src/ThermalConsole.ps1     console version
src/IntelGpuTemp.cs        iGPU temperature via MCHBAR/PawnIO, plus IGCL and WDDM fallbacks
lib/      (git-ignored)    downloaded libraries
data/     (git-ignored)    thermal_log.csv
```

## Security

The tool runs as Administrator, so it is careful about what code it loads:

- **Downloaded libraries are hash-checked.** LibreHardwareMonitorLib 0.9.6 and the PawnIO `IntelMCHBAR` module are checked against pinned SHA-256 hashes, both the archive and each DLL. A mismatch stops the program.
- **Unexpected DLLs are removed.** Any DLL in `lib/` that isn't on the allow-list is deleted before loading, and only allow-listed assemblies are resolved.
- **Downloads are unpacked safely.** They go into random temporary folders.
- **The PawnIO driver's signature is checked.** `PawnIOLib.dll` must have a valid Authenticode signature from `namazso.eu`.
- **System DLLs are loaded by full path** from System32.
- **Nothing is written to hardware.** All hardware access is read-only, and fan speed or power limits are never changed.

## Credits

- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) (MPL-2.0): CPU, GPU, storage and battery sensors.
- [PawnIO](https://github.com/namazso/PawnIO) and [PawnIO.Modules](https://github.com/namazso/PawnIO.Modules): signed driver for MSR and MCHBAR access.
