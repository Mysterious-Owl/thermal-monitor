// Reads Intel GPU temperatures through the Intel Graphics Control Library (IGCL),
// which ships with the Intel graphics driver as C:\Windows\System32\ControlLib.dll.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// Meteor Lake iGPU temperature from the GT thermal status register THERM_STATUS_GT
// (MCHBAR + 0x59C0; bit 31 = valid, bits 23:16 = degrees below TjMax), read through the
// signed, read-only PawnIO "IntelMCHBAR" module. Same method as LibreHardwareMonitor PR #2551.
public static class MchbarGpuTemp
{
    const uint THERM_STATUS_GT = 0x59C0;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibrary(string path);
    [DllImport("PawnIOLib.dll")] static extern int pawnio_open(out IntPtr handle);
    [DllImport("PawnIOLib.dll")] static extern int pawnio_load(IntPtr handle, byte[] blob, UIntPtr size);
    [DllImport("PawnIOLib.dll")] static extern int pawnio_close(IntPtr handle);
    [DllImport("PawnIOLib.dll", CharSet = CharSet.Ansi)]
    static extern int pawnio_execute(IntPtr handle, string name, ulong[] input, UIntPtr inSize,
                                     [Out] ulong[] output, UIntPtr outSize, out UIntPtr returnSize);

    static IntPtr handle = IntPtr.Zero;
    public static string LastError = "";

    public static bool Open(string pawnIoLibPath, string modulePath)
    {
        if (handle != IntPtr.Zero) return true;
        try
        {
            if (!System.IO.File.Exists(pawnIoLibPath)) { LastError = "PawnIO not installed"; return false; }
            if (!System.IO.File.Exists(modulePath)) { LastError = "IntelMCHBAR.bin missing"; return false; }
            if (LoadLibrary(pawnIoLibPath) == IntPtr.Zero) { LastError = "Cannot load PawnIOLib.dll"; return false; }
            int hr = pawnio_open(out handle);
            if (hr != 0) { LastError = "pawnio_open 0x" + hr.ToString("X8") + " (run as Administrator)"; handle = IntPtr.Zero; return false; }
            byte[] blob = System.IO.File.ReadAllBytes(modulePath);
            hr = pawnio_load(handle, blob, (UIntPtr)blob.Length);
            if (hr != 0) { LastError = "pawnio_load 0x" + hr.ToString("X8"); Close(); return false; }
            return true;
        }
        catch (Exception e) { LastError = e.GetType().Name + ": " + e.Message; Close(); return false; }
    }

    // Returns degrees C, or double.NaN if unavailable.
    public static double Read(double tjMax)
    {
        if (handle == IntPtr.Zero) return double.NaN;
        var input = new ulong[] { THERM_STATUS_GT };
        var output = new ulong[1];
        UIntPtr ret;
        int hr = pawnio_execute(handle, "ioctl_read_dword", input, (UIntPtr)1, output, (UIntPtr)1, out ret);
        if (hr != 0 || ret.ToUInt64() != 1) { LastError = "read 0x" + hr.ToString("X8"); return double.NaN; }
        uint v = (uint)output[0];
        if ((v & 0x80000000) == 0) { LastError = "THERM_STATUS_GT not valid (0x" + v.ToString("X8") + ")"; return double.NaN; }
        return tjMax - ((v >> 16) & 0xFF);
    }

    public static void Close()
    {
        if (handle != IntPtr.Zero) { try { pawnio_close(handle); } catch { } handle = IntPtr.Zero; }
    }
}

// Reads GPU temperature the same way Task Manager does: the WDDM kernel-mode thunk
// D3DKMTQueryAdapterInfo(KMTQAITYPE_ADAPTERPERFDATA) in gdi32.dll. Works without admin.
public class WddmGpuTempReading
{
    public string Name;
    public double TempC;
}

public static class WddmGpuTemp
{
    const int KMTQAITYPE_ADAPTERREGISTRYINFO = 8;
    const int KMTQAITYPE_ADAPTERPERFDATA = 62;

    [StructLayout(LayoutKind.Sequential)]
    struct AdapterInfo { public uint hAdapter; public uint LuidLow; public int LuidHigh; public uint NumOfSources; public int bPrecise; }

    [StructLayout(LayoutKind.Sequential)]
    struct EnumAdapters2 { public uint NumAdapters; public IntPtr pAdapters; }

    [StructLayout(LayoutKind.Sequential)]
    struct QueryAdapterInfo { public uint hAdapter; public int Type; public IntPtr pData; public uint DataSize; }

    [StructLayout(LayoutKind.Explicit, Size = 64)]
    struct AdapterPerfData
    {
        [FieldOffset(0)]  public uint PhysicalAdapterIndex;
        [FieldOffset(48)] public uint FanRPM;
        [FieldOffset(52)] public uint Power;
        [FieldOffset(56)] public uint Temperature;   // deci-Celsius
    }

    [StructLayout(LayoutKind.Sequential)]
    struct CloseAdapter { public uint hAdapter; }

    [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref EnumAdapters2 e);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QueryAdapterInfo q);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref CloseAdapter c);

    public static string LastError = "";

    public static WddmGpuTempReading[] Read()
    {
        var list = new List<WddmGpuTempReading>();
        try
        {
            var e = new EnumAdapters2();
            int st = D3DKMTEnumAdapters2(ref e);
            if (st != 0 || e.NumAdapters == 0) { LastError = "EnumAdapters2 0x" + st.ToString("X"); return list.ToArray(); }
            int sz = Marshal.SizeOf(typeof(AdapterInfo));
            e.pAdapters = Marshal.AllocHGlobal(sz * (int)e.NumAdapters);
            try
            {
                st = D3DKMTEnumAdapters2(ref e);
                if (st != 0) { LastError = "EnumAdapters2 0x" + st.ToString("X"); return list.ToArray(); }
                for (int i = 0; i < e.NumAdapters; i++)
                {
                    var ai = (AdapterInfo)Marshal.PtrToStructure(new IntPtr(e.pAdapters.ToInt64() + i * sz), typeof(AdapterInfo));
                    string name = QueryName(ai.hAdapter);
                    if (name == "GPU") { var cc = new CloseAdapter { hAdapter = ai.hAdapter }; D3DKMTCloseAdapter(ref cc); continue; } // non-display (e.g. NPU / render-only)
                    var perf = new AdapterPerfData();
                    IntPtr p = Marshal.AllocHGlobal(64);
                    try
                    {
                        for (int k = 0; k < 64; k++) Marshal.WriteByte(p, k, 0);
                        var q = new QueryAdapterInfo { hAdapter = ai.hAdapter, Type = KMTQAITYPE_ADAPTERPERFDATA, pData = p, DataSize = 64 };
                        st = D3DKMTQueryAdapterInfo(ref q);
                        if (st == 0) perf = (AdapterPerfData)Marshal.PtrToStructure(p, typeof(AdapterPerfData));
                        else LastError = name + ": perfdata 0x" + st.ToString("X");
                    }
                    finally { Marshal.FreeHGlobal(p); }
                    var c = new CloseAdapter { hAdapter = ai.hAdapter };
                    D3DKMTCloseAdapter(ref c);

                    if (name.IndexOf("Basic Render", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                    double t = perf.Temperature / 10.0;
                    if (t > 0 && t < 150) list.Add(new WddmGpuTempReading { Name = name, TempC = Math.Round(t, 1) });
                    else if (st == 0) LastError = name + ": driver reports no temperature";
                }
            }
            finally { Marshal.FreeHGlobal(e.pAdapters); }
        }
        catch (Exception ex) { LastError = ex.GetType().Name + ": " + ex.Message; }
        return list.ToArray();
    }

    static string QueryName(uint h)
    {
        const int size = 260 * 2 * 4;
        IntPtr p = Marshal.AllocHGlobal(size);
        try
        {
            for (int k = 0; k < size; k++) Marshal.WriteByte(p, k, 0);
            var q = new QueryAdapterInfo { hAdapter = h, Type = KMTQAITYPE_ADAPTERREGISTRYINFO, pData = p, DataSize = size };
            if (D3DKMTQueryAdapterInfo(ref q) == 0) { var s = Marshal.PtrToStringUni(p); if (!string.IsNullOrEmpty(s)) return s; }
        }
        finally { Marshal.FreeHGlobal(p); }
        return "GPU";
    }
}

public class IntelGpuTempReading
{
    public int Adapter;
    public string Sensor;
    public double TempC;
    public double MaxC;
}

public static class IntelGpuTemp
{
    const string Dll = "ControlLib.dll";
    const uint CTL_INIT_FLAG_USE_LEVEL_ZERO = 1;

    [StructLayout(LayoutKind.Sequential)]
    struct InitArgs
    {
        public uint Size;
        public byte Version;
        public uint AppVersion;
        public uint Flags;
        public uint SupportedVersion;
        public Guid ApplicationUID;
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct TempProperties
    {
        [FieldOffset(0)]  public uint Size;
        [FieldOffset(4)]  public byte Version;
        [FieldOffset(8)]  public int Type;
        [FieldOffset(16)] public double MaxTemperature;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "LoadLibraryW")]
    static extern IntPtr LoadLibraryW(string path);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int ctlInit(ref InitArgs args, out IntPtr apiHandle);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int ctlClose(IntPtr apiHandle);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, EntryPoint = "ctlEnumerateDevices")]
    static extern int EnumDevicesCount(IntPtr api, ref uint count, IntPtr zero);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, EntryPoint = "ctlEnumerateDevices")]
    static extern int EnumDevices(IntPtr api, ref uint count, [Out] IntPtr[] devices);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, EntryPoint = "ctlEnumTemperatureSensors")]
    static extern int EnumTempCount(IntPtr device, ref uint count, IntPtr zero);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, EntryPoint = "ctlEnumTemperatureSensors")]
    static extern int EnumTemps(IntPtr device, ref uint count, [Out] IntPtr[] sensors);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int ctlTemperatureGetProperties(IntPtr sensor, ref TempProperties props);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int ctlTemperatureGetState(IntPtr sensor, out double temperature);

    static readonly string[] TypeNames = { "GPU Global", "GPU Core", "GPU Memory", "GPU Global Min", "GPU Core Min", "GPU Memory Min" };

    static IntPtr api = IntPtr.Zero;
    static readonly List<KeyValuePair<int, IntPtr>> sensors = new List<KeyValuePair<int, IntPtr>>();
    public static string LastError = "";

    public static bool Open()
    {
        if (api != IntPtr.Zero) return true;
        try
        {
            // Load Intel's ControlLib.dll from System32 by full path (never from the current folder).
            string sysLib = System.IO.Path.Combine(Environment.SystemDirectory, Dll);
            if (!System.IO.File.Exists(sysLib) || LoadLibraryW(sysLib) == IntPtr.Zero) { LastError = "ControlLib.dll not found in System32"; return false; }

            var args = new InitArgs
            {
                Size = (uint)Marshal.SizeOf(typeof(InitArgs)),
                Version = 0,
                AppVersion = (1u << 16) | 1u,           // CTL_MAKE_VERSION(1, 1)
                Flags = CTL_INIT_FLAG_USE_LEVEL_ZERO,   // telemetry APIs need Level Zero
                ApplicationUID = Guid.Empty             // IGCL samples pass an all-zero app id
            };
            int r = ctlInit(ref args, out api);
            if (r != 0) { LastError = "ctlInit failed: 0x" + r.ToString("X"); api = IntPtr.Zero; return false; }

            uint count = 0;
            r = EnumDevicesCount(api, ref count, IntPtr.Zero);
            if (r != 0 || count == 0) { LastError = "No Intel GPU found (0x" + r.ToString("X") + ")"; return false; }
            var devs = new IntPtr[count];
            EnumDevices(api, ref count, devs);

            for (int d = 0; d < count; d++)
            {
                uint n = 0;
                r = EnumTempCount(devs[d], ref n, IntPtr.Zero);
                if (r != 0 || n == 0) { LastError = "No temperature sensors on adapter " + d + " (0x" + r.ToString("X") + ")"; continue; }
                var hs = new IntPtr[n];
                EnumTemps(devs[d], ref n, hs);
                foreach (var h in hs) sensors.Add(new KeyValuePair<int, IntPtr>(d, h));
            }
            return sensors.Count > 0;
        }
        catch (Exception e) { LastError = e.GetType().Name + ": " + e.Message; return false; }
    }

    public static IntelGpuTempReading[] Read()
    {
        var list = new List<IntelGpuTempReading>();
        if (!Open()) return list.ToArray();
        foreach (var kv in sensors)
        {
            double t;
            if (ctlTemperatureGetState(kv.Value, out t) != 0 || t <= 0 || t > 150) continue;
            var p = new TempProperties { Size = 24 };
            string name = "GPU Temperature";
            double max = 0;
            if (ctlTemperatureGetProperties(kv.Value, ref p) == 0)
            {
                if (p.Type >= 0 && p.Type < TypeNames.Length) name = TypeNames[p.Type];
                max = p.MaxTemperature;
            }
            list.Add(new IntelGpuTempReading { Adapter = kv.Key, Sensor = name, TempC = Math.Round(t, 1), MaxC = max });
        }
        return list.ToArray();
    }

    public static void Close()
    {
        if (api != IntPtr.Zero) { try { ctlClose(api); } catch { } api = IntPtr.Zero; }
        sensors.Clear();
    }
}
