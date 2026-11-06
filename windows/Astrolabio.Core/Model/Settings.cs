using System.Text.Json;
using System.Text.Json.Serialization;
using Astrolabio.Core.Astronomy;

namespace Astrolabio.Core.Model;

/// <summary>Carpeta de datos de la app: %APPDATA%\Astrolabio en Windows.</summary>
public static class AppPaths
{
    public static string Data
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Astrolabio");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    public static string DefaultImages =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Astrolabio");
}

/// <summary>Ajustes persistentes (settings.json).</summary>
public sealed class AppSettings : Observable
{
    public string SiteName { get; set; } = Strings.T("Mi observatorio");
    public double Latitude { get; set; } = 40.4818;
    public double Longitude { get; set; } = -3.3643;
    public string TelescopeHost { get; set; } = "192.168.0.37";
    public bool AutoConnect { get; set; }
    public string PemPath { get; set; } = "";
    public double MinAltitude { get; set; } = 30;
    public double MaxCloudCover { get; set; } = 60;
    public int ExposureMs { get; set; } = 10_000;
    public int Gain { get; set; } = 80;
    public double FovWidthDeg { get; set; } = 0.73;
    public double FovHeightDeg { get; set; } = 1.29;
    public string NtfyTopic { get; set; } = "";
    public string NtfyServer { get; set; } = "https://ntfy.sh";
    public string SaveFolder { get; set; } = AppPaths.DefaultImages;
    public int DewHeaterPower { get; set; }
    public bool DitherEnabled { get; set; } = true;
    public int DitherPixels { get; set; } = 50;
    public int DitherInterval { get; set; } = 10;
    public bool AutoFocusBeforeStack { get; set; }
    public bool NightMode { get; set; }
    public bool NightModeAuto { get; set; }
    public double NightBrightness { get; set; } = 0.7;
    public string? Language { get; set; }

    [JsonIgnore] public (double W, double H) Fov => (FovWidthDeg, FovHeightDeg);

    private static string FilePath => Path.Combine(AppPaths.Data, "settings.json");
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static AppSettings Load()
    {
        try { if (File.Exists(FilePath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new(); }
        catch { }
        return new AppSettings();
    }

    public void Save()
    {
        try { File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Options)); } catch { }
        OnPropertyChanged(string.Empty);
    }

    public string SaveFolderPath
    {
        get { Directory.CreateDirectory(SaveFolder); return SaveFolder; }
    }

    public Protocol.SeestarSigner? MakeSigner()
    {
        try { return PemPath.Length > 0 && File.Exists(PemPath) ? Protocol.SeestarSigner.FromFile(PemPath) : null; } catch { return null; }
    }

    public void Notify(string title, string body) =>
        _ = Services.PhoneNotifier.Send(NtfyServer, NtfyTopic, title, body);
}

/// <summary>Un objetivo del plan de la noche.</summary>
public sealed class PlanItem
{
    public enum ItemStatus { Pending, Running, Done, Skipped, Failed }
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public double RaHours { get; set; }
    public double DecDeg { get; set; }
    public double Minutes { get; set; } = 60;
    public bool LpFilter { get; set; }
    public bool Autofocus { get; set; } = true;
    public int MosaicColumns { get; set; } = 1;
    public int MosaicRows { get; set; } = 1;
    public double OverlapPercent { get; set; } = 15;
    public DateTime? NotBefore { get; set; }
    public ItemStatus Status { get; set; }
    public int StackedFrames { get; set; }
    [JsonIgnore] public bool IsMosaic => MosaicColumns * MosaicRows > 1;
}

/// <summary>Plan de la noche, guardado en plan.json.</summary>
public sealed class PlanStore : Observable
{
    public List<PlanItem> Items { get; private set; } = [];
    private static string FilePath => Path.Combine(AppPaths.Data, "plan.json");

    public PlanStore()
    {
        try { if (File.Exists(FilePath)) Items = JsonSerializer.Deserialize<List<PlanItem>>(File.ReadAllText(FilePath)) ?? []; } catch { }
    }

    public void Save()
    {
        try { File.WriteAllText(FilePath, JsonSerializer.Serialize(Items)); } catch { }
        OnPropertyChanged(nameof(Items));
    }

    public void Add(Astronomy.DeepSkyObject o, double minutes = 60, FrameFit? fit = null)
    {
        var item = new PlanItem { Name = o.Id, RaHours = o.RaHours, DecDeg = o.DecDeg, Minutes = minutes, LpFilter = o.Kind.WantsLP() };
        if (fit is { IsMosaic: true }) { item.MosaicColumns = fit.Columns; item.MosaicRows = fit.Rows; }
        Items.Add(item);
        Save();
    }
}
