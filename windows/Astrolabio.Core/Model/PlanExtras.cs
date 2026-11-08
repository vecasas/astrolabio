using System.Text.Json;
using System.Text.Json.Nodes;
using Astrolabio.Core.Astronomy;

namespace Astrolabio.Core.Model;

/// <summary>Horario previsto de un objeto del plan (igual que PlanTimeline.swift).</summary>
public sealed record PlanSlot(Guid ItemId, DateTime Start, DateTime End, double HiddenMinutes, bool AfterDawn, double WaitMinutes)
{
    public bool HasWarning => HiddenMinutes >= 10 || AfterDawn;
}

public static class PlanTimeline
{
    public const double OverheadMinutes = 5;

    public static List<PlanSlot> Schedule(IEnumerable<PlanItem> items, Astro.Night night, DateTime nowUtc, SkyLimit limit, double lat, double lon)
    {
        if (night.DuskStart is not DateTime dusk || night.DawnEnd is not DateTime dawn) return [];
        var cursor = nowUtc > dusk ? nowUtc : dusk;
        var o = new List<PlanSlot>();
        foreach (var it in items.Where(i => i.Status is PlanItem.ItemStatus.Pending or PlanItem.ItemStatus.Running))
        {
            var nb = it.NotBefore?.ToUniversalTime();
            var begin = nb is DateTime n && n > cursor ? n : cursor;
            var minutes = Math.Max(0, it.Minutes - (it.DoneSeconds ?? 0) / 60);
            var end = begin.AddMinutes(OverheadMinutes + minutes);
            var clear = limit.ClearFixed(it.RaHours, it.DecDeg, lat, lon);
            double hidden = 0;
            for (var t = begin.AddMinutes(OverheadMinutes); t < end; t = t.AddMinutes(5)) if (!clear(t)) hidden += 5;
            o.Add(new PlanSlot(it.Id, begin, end, hidden, end > dawn.AddMinutes(1), (begin - cursor).TotalMinutes));
            cursor = end;
        }
        return o;
    }

    public static List<(DateTime From, DateTime To)> VisibleWindows(PlanItem it, DateTime from, DateTime to, SkyLimit limit, double lat, double lon)
    {
        var clear = limit.ClearFixed(it.RaHours, it.DecDeg, lat, lon);
        var o = new List<(DateTime, DateTime)>();
        DateTime? open = null;
        for (var t = from; t <= to; t = t.AddMinutes(5))
        {
            if (clear(t)) open ??= t;
            else if (open is DateTime a) { o.Add((a, t)); open = null; }
        }
        if (open is DateTime b) o.Add((b, to));
        return o;
    }
}

/// <summary>Proyecto de varias noches (igual que Projects.swift).</summary>
public sealed class Project
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string ObjectId { get; set; } = "";
    public double GoalHours { get; set; } = 10;
    public DateTime Created { get; set; } = DateTime.UtcNow;
}

public sealed record ProjectProgress(double Hours, int Nights, DateTime? Last)
{
    public double Fraction(double goal) => goal > 0 ? Math.Min(1, Hours / goal) : 0;
}

public sealed class ProjectStore : Observable
{
    private readonly string _path;
    public List<Project> Projects { get; private set; } = [];

    public ProjectStore(string? path = null)
    {
        _path = path ?? Path.Combine(AppPaths.Data, "projects.json");
        try { if (File.Exists(_path)) Projects = JsonSerializer.Deserialize<List<Project>>(File.ReadAllText(_path)) ?? []; } catch { }
    }

    public void Save()
    {
        try { File.WriteAllText(_path, JsonSerializer.Serialize(Projects)); } catch { }
        OnPropertyChanged(nameof(Projects));
    }

    public void Replace(List<Project> list) { Projects = list; Save(); }

    public static ProjectProgress Progress(string objectId, IEnumerable<ObservationRecord> records)
    {
        var key = Catalog.Normalize(objectId);
        var mine = records.Where(r => Catalog.Find(r.Target) is { } o ? Catalog.Normalize(o.Id) == key : Catalog.Normalize(r.Target) == key).ToList();
        return new(mine.Sum(r => r.IntegrationMinutes) / 60, mine.Select(r => r.NightDate).Distinct().Count(), mine.Count == 0 ? null : mine.Max(r => r.End));
    }

    public static double MinutesForTonight(double goalHours, double doneHours) => Math.Round(Math.Max(0, Math.Min(120, (goalHours - doneHours) * 60)));
}

/// <summary>Copia de seguridad: ajustes (sin la clave PEM), plan, proyectos e historial.</summary>
public sealed class BackupFile
{
    public const int CurrentVersion = 1;
    public const long MaxBytes = 50L * 1024 * 1024;

    public const string FormatName = "astrolabio-backup";
    // Vacío por defecto: un JSON sin este campo no es una copia de Astrolabio.
    public string Format { get; set; } = "";
    public int Version { get; set; } = CurrentVersion;
    public DateTime Created { get; set; } = DateTime.UtcNow;
    public JsonObject Settings { get; set; } = new();
    public List<PlanItem> Plan { get; set; } = [];
    public List<Project> Projects { get; set; } = [];
    public List<ObservationRecord> History { get; set; } = [];

    public static BackupFile Make(AppSettings s, IEnumerable<PlanItem> plan, IEnumerable<Project> projects, IEnumerable<ObservationRecord> history)
    {
        var settings = JsonSerializer.SerializeToNode(s) as JsonObject ?? new JsonObject();
        settings.Remove("PemPath");                        // nunca la clave
        return new BackupFile { Format = FormatName, Settings = settings, Plan = plan.ToList(), Projects = projects.ToList(), History = history.ToList() };
    }

    public string Encoded() => JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });

    public static BackupFile Decode(string json)
    {
        if (json.Length > MaxBytes) throw new InvalidDataException(Strings.T("El archivo es demasiado grande para ser una copia de Astrolabio."));
        BackupFile? b;
        try { b = JsonSerializer.Deserialize<BackupFile>(json); } catch { b = null; }
        if (b is null || b.Format != FormatName) throw new InvalidDataException(Strings.T("Este archivo no es una copia de seguridad de Astrolabio."));
        if (b.Version > CurrentVersion) throw new InvalidDataException(Strings.T("La copia es de una versión más nueva de Astrolabio. Actualiza la app primero."));
        return b;
    }

    /// <summary>Ajustes de la copia conservando la clave PEM actual.</summary>
    public AppSettings RestoredSettings(AppSettings current)
    {
        var node = (JsonObject)Settings.DeepClone();
        node.Remove("PemPath");
        var s = node.Deserialize<AppSettings>() ?? new AppSettings();
        s.PemPath = current.PemPath;
        return s;
    }
}
