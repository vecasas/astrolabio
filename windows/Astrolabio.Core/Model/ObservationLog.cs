using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Protocol;

namespace Astrolabio.Core.Model;

public sealed record ObservationRecord(Guid Id, string Target, DateTime Start, DateTime End, int Frames, int ExposureMs)
{
    public double IntegrationMinutes => Frames * ExposureMs / 60_000.0;
    public DateTime NightDate => Start.ToLocalTime().AddHours(-12).Date;
    public ObjectKind? Kind => Catalog.Find(Target)?.Kind;
}

/// <summary>Historial de sesiones de apilado (history.json): base de las estadísticas.</summary>
public sealed partial class ObservationLog : Observable
{
    public List<ObservationRecord> Records { get; private set; } = [];
    public ObservationRecord? Current { get; private set; }
    private readonly string _path;
    private DateTime _lastUpdate = DateTime.MinValue;
    private SeestarClient? _client;
    private Func<int> _exposure = () => 10_000;

    public ObservationLog(string? path = null)
    {
        _path = path ?? Path.Combine(AppPaths.Data, "history.json");
        try { if (File.Exists(_path)) Records = JsonSerializer.Deserialize<List<ObservationRecord>>(File.ReadAllText(_path)) ?? []; } catch { }
    }

    public IEnumerable<ObservationRecord> All => Current is null ? Records : Records.Append(Current);

    public void Attach(SeestarClient client, Func<int> exposureMs)
    {
        _client = client;
        _exposure = exposureMs;
        client.EventReceived += e => { if (e.Name == "Stack") HandleStack(e); };
        _ = Task.Run(async () =>
        {
            while (true)
            {
                await Task.Delay(60_000);
                if (Current is not null && (DateTime.Now - _lastUpdate).TotalSeconds > 900) CloseCurrent();
            }
        });
    }

    private string TargetName(SeestarEvent e)
    {
        foreach (var c in new[] { e.Data.Str("target_name"), _client?.ViewTarget,
                     _client?.LastEvents.GetValueOrDefault("AutoGoto")?.Data.Str("target_name") })
            if (!string.IsNullOrEmpty(c)) return c;
        return Strings.T("Sin nombre");
    }

    public void HandleStack(SeestarEvent e, DateTime? nowOpt = null)
    {
        var now = nowOpt ?? DateTime.UtcNow;
        if (e.Data.Int("stacked_frame") is int frames)
        {
            var name = TargetName(e);
            if (Current is { } cur && cur.Target == name && frames >= cur.Frames) Current = cur with { Frames = frames, End = now };
            else
            {
                CloseCurrent();
                var exp = _client?.StackExposureMs ?? _exposure();
                Current = new ObservationRecord(Guid.NewGuid(), name, now.AddSeconds(-frames * exp / 1000.0), now, frames, exp);
            }
            _lastUpdate = DateTime.Now;
            OnPropertyChanged(nameof(Current));
        }
        if (e.State is "complete" or "cancel" or "fail") CloseCurrent();
    }

    public void CloseCurrent()
    {
        if (Current is not { } cur) return;
        Current = null;
        if (cur.Frames >= 3) { Records.Add(cur); Save(); }
        OnPropertyChanged(nameof(Current));
    }

    public void Delete(IEnumerable<Guid> ids) { var s = ids.ToHashSet(); Records.RemoveAll(r => s.Contains(r.Id)); Save(); }

    [GeneratedRegex(@"Stacked_(\d+)_(?:mosaic_)?(.+?)_(\d+(?:\.\d+)?)s_[A-Za-z0-9]+_(\d{8}-\d{6})")]
    private static partial Regex StackedName();

    /// <summary>Importa las sesiones del álbum del Seestar a partir de los nombres de las imágenes apiladas.</summary>
    public int ImportFromAlbum(JsonObject reply)
    {
        if (reply.At("result.list") is not JsonArray groups) return 0;
        var added = 0;
        foreach (var g in groups.OfType<JsonObject>())
        foreach (var f in (g["files"] as JsonArray ?? []).OfType<JsonObject>())
        {
            var thn = f.Str("thn");
            if (thn is null) continue;
            var m = StackedName().Match(Path.GetFileName(thn));
            if (!m.Success) continue;
            var frames = int.Parse(m.Groups[1].Value);
            var expMs = (int)(double.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture) * 1000);
            var end = DateTime.ParseExact(m.Groups[4].Value, "yyyyMMdd-HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal).ToUniversalTime();
            var target = m.Groups[2].Value;
            if (frames < 1 || Records.Any(r => Catalog.Normalize(r.Target) == Catalog.Normalize(target) && Math.Abs((r.End - end).TotalMinutes) < 30)) continue;
            Records.Add(new ObservationRecord(Guid.NewGuid(), target, end.AddSeconds(-frames * expMs / 1000.0), end, frames, expMs));
            added++;
        }
        if (added > 0) { Records.Sort((a, b) => a.Start.CompareTo(b.Start)); Save(); }
        return added;
    }

    private void Save()
    {
        try { File.WriteAllText(_path, JsonSerializer.Serialize(Records, new JsonSerializerOptions { WriteIndented = true })); } catch { }
        OnPropertyChanged(nameof(Records));
    }

    public string Csv()
    {
        var sb = new StringBuilder("objeto,inicio,fin,fotogramas,exposicion_ms,minutos\n");
        foreach (var r in All)
            sb.Append(CultureInfo.InvariantCulture, $"\"{r.Target}\",{r.Start:O},{r.End:O},{r.Frames},{r.ExposureMs},{r.IntegrationMinutes:F1}\n");
        return sb.ToString();
    }
}
