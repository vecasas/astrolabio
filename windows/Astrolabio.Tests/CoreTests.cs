using System.Text.Json.Nodes;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Imaging;
using Astrolabio.Core.Model;
using Astrolabio.Core.Protocol;
using Astrolabio.Core.Reports;
using Astrolabio.Core.Services;
using Xunit;

namespace Astrolabio.Tests;

// Las mismas comprobaciones que las pruebas de la versión de macOS.
public class AstroTests
{
    [Fact] public void JulianDayJ2000() => Assert.Equal(2451545.0, Astro.JulianDay(new DateTime(2000, 1, 1, 12, 0, 0, DateTimeKind.Utc)), 6);

    [Fact]
    public void PolarisAltitudeEqualsLatitude()
    {
        var alt = Astro.AltAz(2.53, 89.26, DateTime.UtcNow, 40.48, -3.36).Alt;
        Assert.InRange(alt, 40.48 - 1.2, 40.48 + 1.2);
    }

    [Fact]
    public void CatalogHasMessier()
    {
        Assert.Equal(110, Catalog.Objects.Count(o => o.Id.StartsWith('M') && !o.Id.Contains(' ')));
        Assert.NotNull(Catalog.Find("m31"));
        Assert.NotNull(Catalog.Find("Gran Nebulosa de Orion"));
    }

    [Fact]
    public void ParsesCoordinates()
    {
        Assert.Equal(5.59, Astro.ParseSexagesimal("05h 35m 24s")!.Value, 3);
        Assert.Equal(-5.45, Astro.ParseSexagesimal("-05° 27′ 00″")!.Value, 3);
    }

    [Fact] public void MosaicPanels() => Assert.Equal(6, Planner.MosaicPanels(21, 44, 3, 2, 15, (0.73, 1.29)).Count);

    [Fact]
    public void NextPhasesAreAboutAWeekApart()
    {
        var p = Ephemeris.NextPhases(new DateTime(2026, 10, 26, 0, 0, 0, DateTimeKind.Utc));
        Assert.Equal(4, p.Count);
        for (var i = 1; i < p.Count; i++) Assert.InRange((p[i].Date - p[i - 1].Date).TotalDays, 6, 8.5);
    }

    [Fact]
    public void PlanetsResolve()
    {
        foreach (var n in Astro.PlanetNames) { var p = Astro.Planet(n, DateTime.UtcNow); Assert.NotNull(p); Assert.InRange(p!.Value.Ra, 0, 24); }
    }

    [Fact]
    public void StarDataLoads()
    {
        Assert.True(SkyCatalog.Stars.Count > 2800);
        Assert.True(SkyCatalog.ConstellationLines.Count > 100);
        Assert.Contains(SkyCatalog.Labels, l => l.Names[0] == "Orión");
    }
}

public class ProtocolTests
{
    [Fact]
    public void VerifyMarkerRules()
    {
        var c = new SeestarClient();
        var m = c.WithVerify(new JsonObject { ["id"] = 1, ["method"] = "get_device_state" });
        Assert.Equal("verify", m["params"]![0]!.GetValue<string>());
        var albums = c.WithVerify(new JsonObject { ["id"] = 2, ["method"] = "get_albums" });
        Assert.Null(albums["params"]);                 // con el marcador, el álbum sale vacío
        var list = c.WithVerify(new JsonObject { ["id"] = 3, ["method"] = "set_control_value", ["params"] = new JsonArray("gain", 80) });
        Assert.Equal(3, list["params"]!.AsArray().Count);
    }

    [Fact]
    public void ImportsAlbumNames()
    {
        var reply = JsonNode.Parse("""
        {"result":{"path":"MyWorks","list":[{"group_name":"DeepSky","files":[
          {"name":"M45_sub","thn":"M45_sub/Light_M45_30.0s_IRCUT_20261105-231119_thn.jpg","count":63},
          {"name":"M 45","thn":"M 45/Stacked_25_M 45_30.0s_IRCUT_20261030-234613_thn.jpg","count":1},
          {"name":"NGC 1981_mosaic","thn":"NGC 1981_mosaic/Stacked_8_mosaic_NGC 1981_30.0s_IRCUT_20261031-001229_thn.jpg","count":1}]}]}}
        """)!.AsObject();
        var log = new ObservationLog(Path.Combine(Path.GetTempPath(), $"hist_{Guid.NewGuid()}.json"));
        Assert.Equal(2, log.ImportFromAlbum(reply));
        Assert.Equal(0, log.ImportFromAlbum(reply));
        Assert.Contains(log.Records, r => r.Target == "M 45" && r.Frames == 25 && Math.Abs(r.IntegrationMinutes - 12.5) < 0.01);
    }
}

[Collection("Idioma")]
public class LocalizationTests
{
    [Fact]
    public void FormatsAppleStyle()
    {
        Assert.Equal("Apuntando a M31…", Strings.Format("Apuntando a %@…", "M31"));
        Assert.Equal("40° y 70° a las 23:40", Strings.Format("%1$.0f° y %2$.0f° a las %3$@", 40.0, 70.0, "23:40"));
        Assert.Equal("Batería 80 %", Strings.Format("Batería %@ %%", 80));
    }

    [Fact]
    public void TranslatesAndSwitches()
    {
        var original = Strings.Language;
        try
        {
            Strings.SetLanguage(AppLanguage.en);
            Assert.Equal("Moon", Strings.T("Luna"));
            Assert.Equal("Galaxy", ObjectKind.Galaxy.Label());
            Strings.SetLanguage(AppLanguage.de);
            Assert.Equal("Es steht bei 40° und steigt bis gegen 23:40 auf 70°.", Strings.T("Está a %.0f° y sube hasta %.0f° hacia las %@.", 40.0, 70.0, "23:40"));
        }
        finally { Strings.SetLanguage(original); }
    }

    [Fact]
    public void CatalogNamesTranslated()
    {
        var names = Catalog.Objects.Select(o => o.Name).Where(n => n.Length > 0).Concat(Astro.PlanetNames).Distinct().ToList();
        foreach (var lang in new[] { AppLanguage.en, AppLanguage.fr, AppLanguage.de, AppLanguage.zh, AppLanguage.ru })
            Assert.Empty(Strings.Missing(names, lang));
    }
}

public class ProcessingTests
{
    [Fact]
    public void GradientRemovalFlattens()
    {
        int w = 400, h = 600; var rnd = new Random(7);
        var r = new float[w * h]; var g = new float[w * h]; var b = new float[w * h];
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
        {
            var i = y * w + x; var grad = (float)y / h * 800;
            r[i] = 18000 + grad * 1.3f + (float)(rnd.NextDouble() * 80 - 40);
            g[i] = 18000 + grad + (float)(rnd.NextDouble() * 80 - 40);
            b[i] = 18000 + grad * 0.6f + (float)(rnd.NextDouble() * 80 - 40);
        }
        var img = new LinearImage(w, h, r, g, b);
        ImageProcessing.SubtractBackgroundModel(img);
        ImageProcessing.NeutralizeBackground(img);
        float Row(float[] c, int y) { float s = 0; for (var x = 0; x < w; x++) s += c[y * w + x]; return s / w; }
        Assert.InRange(Math.Abs(Row(img.G, 10) - Row(img.G, h - 10)), 0, 40);
        Assert.InRange(Math.Abs(Row(img.R, 300) - Row(img.B, 300)), 0, 30);
        var rendered = ImageProcessing.Render(img, new ProcessingOptions());
        Assert.Equal(img.Width * img.Height * 4, rendered.Bgra.Length);
    }

    [Fact]
    public void CropsTiltedBorder()
    {
        int w = 400, h = 600; var rnd = new Random(3);
        var r = new float[w * h]; var g = new float[w * h]; var b = new float[w * h];
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
        {
            var i = y * w + x; var band = x >= w - (int)((double)y / h * 40); var a = band ? 130 : 40;
            r[i] = 18000 + (float)(rnd.NextDouble() * 2 * a - a) + (band ? -250 : 0);
            g[i] = 18000 + (float)(rnd.NextDouble() * 2 * a - a);
            b[i] = 18000 + (float)(rnd.NextDouble() * 2 * a - a) + (band ? 300 : 0);
        }
        var c = ImageProcessing.CropStackEdges(new LinearImage(w, h, r, g, b));
        Assert.InRange(c.Width, w - 90, w - 30);
        Assert.InRange(c.Height, h - 30, h);
    }
}

[Collection("Idioma")]
public class ReportTests
{
    private static ObservationRecord Rec(string t, DateTime localStart, double minutes, int frames) =>
        new(Guid.NewGuid(), t, localStart.ToUniversalTime(), localStart.AddMinutes(minutes).ToUniversalTime(), frames, 10_000);

    [Fact]
    public void ZeroPaddedFormat() => Assert.Equal("1 h 05 min", Strings.Format("%d h %02d min", 1, 5));

    [Fact]
    public void GroupsByNightNewestFirst()
    {
        var nights = NightSession.Group([
            Rec("M 31", new DateTime(2026, 11, 1, 22, 0, 0, DateTimeKind.Local), 30, 180),
            Rec("M 45", new DateTime(2026, 11, 2, 1, 30, 0, DateTimeKind.Local), 20, 120),
            Rec("M 42", new DateTime(2026, 11, 3, 23, 0, 0, DateTimeKind.Local), 10, 60)]);
        Assert.Equal(2, nights.Count);
        Assert.Equal(["M 42"], nights[0].Targets);
        Assert.Equal(["M 31", "M 45"], nights[1].Targets);
        Assert.Equal(300, nights[1].Frames);
    }

    [Fact]
    public void OldHistoryJsonStillDecodes()
    {
        var json = """[{"Id":"6f1c4d2e-9c1b-4e55-8b7a-1d2e3f4a5b6c","Target":"M 31","Start":"2026-11-01T21:00:00Z","End":"2026-11-01T21:30:00Z","Frames":180,"ExposureMs":10000}]""";
        var recs = System.Text.Json.JsonSerializer.Deserialize<List<ObservationRecord>>(json)!;
        Assert.Single(recs);
        Assert.Null(recs[0].Gain);
        Assert.NotNull(recs[0].Coordinates);
    }

    [Fact]
    public void ReportContentAndPdf()
    {
        var original = Strings.Language;
        try
        {
            Strings.SetLanguage(AppLanguage.es);
            var r = Rec("M 31", new DateTime(2026, 11, 1, 22, 0, 0, DateTimeKind.Local), 30, 180) with
            {
                Gain = 80, LpFilter = true, Dropped = 4, DitherEnabled = true, DitherPixels = 50, DitherInterval = 10,
                BatteryStart = 92, BatteryEnd = 81, Firmware = "4.43", Device = "Seestar S50",
                Weather = new WeatherSnapshot(12, 8.5, 2.1, 64, 7),
                Events = Enumerable.Range(0, 120).Select(i => $"22:{i % 60:00}  evento {i}").ToList(),
            };
            var doc = ReportDocument.Make(NightSession.Group([r])[0], site: ("Casa", 40.48, -3.36));
            Assert.Contains(doc.Summary, x => x.Label == "Integración total" && x.Value == "30 min");
            Assert.Contains(doc.Conditions, x => x.Label == "Nubes" && x.Value == "12 %");
            Assert.Contains(doc.Objects[0].Rows, x => x.Label == "Filtro LP" && x.Value == "Sí");
            Assert.Contains(doc.Device, x => x.Value == "92 % / 81 %");
            var pdf = ReportPdf.Render(doc);
            Assert.True(pdf.Length > 2000);
            Assert.Equal("%PDF", System.Text.Encoding.ASCII.GetString(pdf, 0, 4));

            Strings.SetLanguage(AppLanguage.zh);
            var zh = ReportDocument.Make(NightSession.Group([r])[0]);
            Assert.NotEqual("Informe de sesión", zh.Title);
            Assert.True(ReportPdf.Render(zh).Length > 2000);
        }
        finally { Strings.SetLanguage(original); }
    }
}

[Collection("Idioma")]
public class SafetyTests
{
    private static readonly GotoSafety.Limits Madrid = new(40.48, -3.36, 15, 30);

    [Fact]
    public void BlocksTheSun()
    {
        var t = new DateTime(2026, 11, 6, 12, 0, 0, DateTimeKind.Utc);
        var sun = Astro.Sun(t);
        Assert.NotNull(GotoSafety.Check(sun.Ra, sun.Dec, t, Madrid));
        Assert.NotNull(GotoSafety.Check(sun.Ra, sun.Dec + 10, t, Madrid with { MinSunSeparation = 0, MinAltitude = -90 }));
    }

    [Fact]
    public void BlocksLowTargetsAndAllowsHighOnes()
    {
        var t = new DateTime(2026, 11, 6, 22, 0, 0, DateTimeKind.Utc);
        var polaris = Astro.PrecessFromJ2000(2.53, 89.26, t);
        Assert.Null(GotoSafety.Check(polaris.Ra, polaris.Dec, t, Madrid));
        Assert.NotNull(GotoSafety.Check(polaris.Ra, polaris.Dec, t, Madrid with { MinAltitude = 50 }));
        Assert.NotNull(GotoSafety.Check(6.4, -70, t, Madrid));
    }

    [Fact]
    public void BatteryEstimate_()
    {
        var t0 = DateTime.UtcNow;
        ObservationRecord Rec(double minutes, int b1, int b2) =>
            new(Guid.NewGuid(), "M 31", t0, t0.AddMinutes(minutes), 100, 10_000) { BatteryStart = b1, BatteryEnd = b2 };
        Assert.Equal(BatteryEstimate.DefaultDrainPerHour, BatteryEstimate.DrainPerHour([]));
        Assert.Equal(12, BatteryEstimate.DrainPerHour([Rec(60, 90, 78), Rec(120, 80, 56), Rec(10, 50, 40)]), 3);
        Assert.True(BatteryEstimate.IsEnough(80, false, 4, 12));
        Assert.False(BatteryEstimate.IsEnough(50, false, 4, 12));
        Assert.True(BatteryEstimate.IsEnough(5, true, 8, 12));
        var a = new PlanItem { Name = "M 31", Minutes = 120, DoneSeconds = 3600 };
        var b = new PlanItem { Name = "M 45", Minutes = 60, Status = PlanItem.ItemStatus.Done };
        Assert.Equal(66.0 / 60, BatteryEstimate.PlanHours([a, b]), 3);
    }

    [Fact]
    public void AlertLimiterAndHealth()
    {
        var l = new AlertLimiter(TimeSpan.FromMinutes(30));
        var t = DateTime.Now;
        Assert.True(l.ShouldSend("battery", t));
        Assert.False(l.ShouldSend("battery", t.AddMinutes(10)));
        Assert.True(l.ShouldSend("storage", t.AddMinutes(10)));
        Assert.True(l.ShouldSend("battery", t.AddMinutes(31)));
        Assert.Empty(HealthCheck.Issues(true, 80, false, 20_000, true, 0));
        Assert.Equal(new[] { "battery", "storage" }, HealthCheck.Issues(true, 15, false, 500, false, 0).Select(i => i.Kind));
        Assert.Empty(HealthCheck.Issues(true, 15, true, null, false, 0));
        Assert.Equal(new[] { "silent" }, HealthCheck.Issues(false, null, false, null, true, 240).Select(i => i.Kind));
    }

    [Fact]
    public void RecenterAndProgress()
    {
        var off = RecenterPolicy.OffsetArcmin(5, 20, 5, 20.05);
        Assert.Equal(3, off, 2);
        Assert.Equal(RecenterPolicy.Decision.Recenter, RecenterPolicy.Decide(off, 2));
        Assert.Equal(RecenterPolicy.Decision.Centered, RecenterPolicy.Decide(1.2, 2));
        Assert.Equal(RecenterPolicy.Decision.Unreliable, RecenterPolicy.Decide(600, 2));
        Assert.Equal(new double[] { 0, 600, 900, 900 }, PlanProgress.RemainingPerPanel(3600, 4, 1200));
    }

    [Fact]
    public void ResumeStateExpires()
    {
        var old = SessionRunner.StatePath;
        SessionRunner.StatePath = Path.Combine(Path.GetTempPath(), $"runner-{Guid.NewGuid()}.json");
        try
        {
            var st = new SessionRunner.SavedState(DateTime.UtcNow.AddHours(-1), true, true, true);
            SessionRunner.SaveState(st);
            Assert.Equal(st, SessionRunner.PendingResume());
            Assert.Null(SessionRunner.PendingResume(DateTime.UtcNow.AddHours(20)));
            SessionRunner.SaveState(null);
            Assert.Null(SessionRunner.PendingResume());
        }
        finally { SessionRunner.StatePath = old; }
    }
}

public class NightWatchTests
{
    private static float[] Field(double sigma, int width = 400, int height = 300, int stars = 40, ulong seed = 7)
    {
        var rng = seed;
        double Rand() { rng = rng * 6364136223846793005UL + 1442695040888963407UL; return (rng >> 11) / (double)(1UL << 53); }
        var img = new float[width * height];
        for (var i = 0; i < img.Length; i++) img[i] = 0.05f + (float)((Rand() - 0.5) * 0.004);
        for (var s = 0; s < stars; s++)
        {
            double cx = 20 + Rand() * (width - 40), cy = 20 + Rand() * (height - 40), amp = 0.2 + Rand() * 0.5;
            for (var y = Math.Max(0, (int)cy - 12); y <= Math.Min(height - 1, (int)cy + 12); y++)
                for (var x = Math.Max(0, (int)cx - 12); x <= Math.Min(width - 1, (int)cx + 12); x++)
                    img[y * width + x] += (float)(amp * Math.Exp(-((x - cx) * (x - cx) + (y - cy) * (y - cy)) / (2 * sigma * sigma)));
        }
        return img;
    }

    [Fact]
    public void HfrGrowsWithBlur()
    {
        var sharp = StarMetrics.Measure(Field(1.2), 400, 300)!;
        var soft = StarMetrics.Measure(Field(2.4), 400, 300)!;
        Assert.True(sharp.Stars >= 10);
        Assert.InRange(sharp.Hfr, 1.18 * 1.2 - 0.35, 1.18 * 1.2 + 0.35);
        Assert.True(soft.Hfr > sharp.Hfr * 1.6);
        Assert.Null(StarMetrics.Measure(new float[400 * 300], 400, 300));
        Assert.Null(StarMetrics.Measure([], 400, 300));
    }

    [Fact]
    public void FocusWatchWarnsOnSoftening()
    {
        var w = new FocusWatch(0.3);
        foreach (var h in new[] { 2.0, 2.1, 2.0 }) Assert.IsType<FocusWatch.Verdict.Learning>(w.Add(h, "M 31"));
        Assert.IsType<FocusWatch.Verdict.Ok>(w.Add(2.1, "M 31"));
        w.Add(2.9, "M 31"); w.Add(3.0, "M 31");
        Assert.IsType<FocusWatch.Verdict.Softening>(w.Add(3.1, "M 31"));
        Assert.IsType<FocusWatch.Verdict.Learning>(w.Add(3.1, "M 45"));
        Assert.Equal(DewRisk.High, Dew.Level(10, 8.5));
        Assert.Equal(DewRisk.Possible, Dew.Level(10, 7));
        Assert.Equal(DewRisk.Low, Dew.Level(10, 2));
    }

    private const string Feed = """
    {"warnings":[{"alert":{"info":[
      {"area":[{"areaDesc":"Campiña de Madrid"},{"areaDesc":"Sierra de Madrid"}],"event":"Tormentas","headline":"Aviso de tormentas",
       "onset":"2026-11-08T18:00:00-00:00","expires":"2026-11-08T23:59:59-00:00",
       "parameter":[{"value":"2; yellow; Moderate","valueName":"awareness_level"},{"value":"3; thunderstorm","valueName":"awareness_type"}]}]}},
     {"alert":{"info":[{"area":[{"areaDesc":"Campiña de Madrid"}],"event":"Niebla","onset":"2026-11-08T18:00:00-00:00","expires":"2026-11-09T06:00:00-00:00",
       "parameter":[{"value":"2; yellow","valueName":"awareness_level"},{"value":"4; fog","valueName":"awareness_type"}]}]}},
     {"basura":true}]}
    """;

    [Fact]
    public void MeteoAlarmAndStormGuard()
    {
        var w = MeteoAlarm.Parse(Feed);
        Assert.Equal(3, w.Count);
        Assert.Equal(new[] { "Campiña de Madrid", "Sierra de Madrid" }, MeteoAlarm.Areas(w));
        Assert.Empty(MeteoAlarm.Parse("no es json"));
        var zone = w.Where(x => x.Area == "Campiña de Madrid").ToList();
        var during = new DateTime(2026, 11, 8, 20, 0, 0, DateTimeKind.Utc);
        var before = new DateTime(2026, 11, 8, 12, 0, 0, DateTimeKind.Utc);
        Assert.NotNull(StormGuard.Reason(zone, [], during));
        Assert.Null(StormGuard.Reason(zone, [], before));
        WeatherHour H(DateTime t, int code = 0, double rain = 0, double gust = 0) => new(t, 50, 0, 70, 10, 5, 10, rain, gust, code);
        Assert.NotNull(StormGuard.Reason([], [H(before.AddMinutes(30), code: 95)], before));
        Assert.NotNull(StormGuard.Reason([], [H(before.AddMinutes(30), rain: 1.2)], before));
        Assert.NotNull(StormGuard.Reason([], [H(before.AddMinutes(30), gust: 62)], before));
        Assert.Null(StormGuard.Reason([], [H(before.AddMinutes(30), rain: 0.1, gust: 30)], before));
        Assert.Null(StormGuard.Reason([], [H(before.AddHours(5), code: 96)], before));
    }

    [Fact]
    public void RainRadarParsing()
    {
        var r = RainRadar.Parse("""{"host":"https://tilecache.rainviewer.com","radar":{"past":[{"time":1794128400,"path":"/v2/radar/abc"},{"time":1,"path":"../evil"}]}}""");
        Assert.Single(r.Frames);
        Assert.Equal("", RainRadar.Parse("""{"host":"http://inseguro","radar":{"past":[]}}""").Host);
        var m = RainRadar.Tile(40.42, -3.70, 6);
        Assert.Equal((31, 24), (m.X, m.Y));
    }
}

public class SecurityTests
{
    [Fact]
    public void FileNamesCannotEscape()
    {
        var evil = SafeName.FileComponent("../../Library/LaunchAgents");
        Assert.DoesNotContain("/", evil); Assert.DoesNotContain("..", evil);
        Assert.DoesNotContain("\\", SafeName.FileComponent("..\\..\\Windows\\System32"));
        Assert.Equal("Seestar", SafeName.FileComponent("..."));
        Assert.Equal("Seestar", SafeName.FileComponent(""));
        Assert.Equal("_CON", SafeName.FileComponent("CON"));
        Assert.Equal("M 31", SafeName.FileComponent("M 31"));
        var b = Path.Combine(Path.GetTempPath(), "astro-base");
        Assert.True(SafeName.IsInside(Path.Combine(b, "M 31", "x.jpg"), b));
        Assert.False(SafeName.IsInside(Path.Combine(b, "..", "fuera.jpg"), b));
    }

    [Fact]
    public void CsvAndNetPolicies()
    {
        Assert.Equal("\"'=HYPERLINK(\"\"x\"\")\"", Csv.Field("=HYPERLINK(\"x\")"));
        Assert.Equal("\"a\"\"b\"", Csv.Field("a\"b"));
        Assert.Equal("https://ntfy.sh/astro-1", NetPolicy.NtfyUrl("https://ntfy.sh", "astro-1")?.ToString());
        Assert.Null(NetPolicy.NtfyUrl("http://ntfy.sh", "abc"));
        Assert.NotNull(NetPolicy.NtfyUrl("http://192.168.1.10:8080", "abc"));
        Assert.Null(NetPolicy.NtfyUrl("https://ntfy.sh", "../admin"));
        Assert.True(NetPolicy.IsLocal("192.168.0.37"));
        Assert.False(NetPolicy.IsLocal("8.8.8.8"));
        Assert.True(NetPolicy.IsWikipedia("https://es.wikipedia.org/wiki/M31"));
        Assert.False(NetPolicy.IsWikipedia("https://wikipedia.org.malo.com/x"));
        Assert.Equal("Hola  X: 1", NetPolicy.HeaderValue("Hola\r\nX: 1"));
    }

    [Fact]
    public void ZipBombIsRejected()
    {
        // ZIP real con 200 MB de ceros comprimidos (ocupa ~200 KB): supera el límite de 128 MB.
        using var ms = new MemoryStream();
        using (var z = new System.IO.Compression.ZipArchive(ms, System.IO.Compression.ZipArchiveMode.Create, true))
        {
            using var s = z.CreateEntry("raw_data", System.IO.Compression.CompressionLevel.Optimal).Open();
            var zeros = new byte[1 << 20];
            for (var i = 0; i < 200; i++) s.Write(zeros);
        }
        Assert.Null(ImageStream.ExtractZip(ms.ToArray(), "raw_data"));
        Assert.Null(ImageStream.ExtractZip([1, 2, 3], "raw_data"));
    }
}

/// <summary>Pruebas de extremo a extremo contra el Seestar simulado.</summary>
[Collection("Red")]
public class ProtocolIntegrationTests
{
    private static async Task<bool> WaitUntil(Func<bool> cond, double seconds = 5)
    {
        var end = DateTime.Now.AddSeconds(seconds);
        while (DateTime.Now < end) { if (cond()) return true; await Task.Delay(50); }
        return cond();
    }

    private static async Task<SeestarClient> Connect(FakeSeestar fake, SeestarSigner? signer = null)
    {
        var c = new SeestarClient { Port = fake.Port, SignerProvider = () => signer };
        await c.ConnectAsync("127.0.0.1");
        return c;
    }

    [Fact]
    public async Task ConnectsAuthenticatesAndReadsState()
    {
        using var fake = new FakeSeestar();
        using var rsa = System.Security.Cryptography.RSA.Create(2048);
        var pub = System.Security.Cryptography.RSA.Create(); pub.ImportParameters(rsa.ExportParameters(false));
        fake.PublicKey = pub;
        var c = await Connect(fake, new SeestarSigner(rsa.ExportRSAPrivateKeyPem()));
        try
        {
            Assert.True(c.IsConnected);
            Assert.True(await WaitUntil(() => c.IsAuthenticated && c.FirmwareVersion == 2706));
            Assert.True(await WaitUntil(() => c.Battery == 87 && c.DeviceName == "Seestar S50 simulado"));
        }
        finally { c.Disconnect(); }
    }

    [Fact]
    public async Task WrongKeyIsRejected()
    {
        using var fake = new FakeSeestar();
        using var expected = System.Security.Cryptography.RSA.Create(2048);
        using var other = System.Security.Cryptography.RSA.Create(2048);
        fake.PublicKey = expected;
        var c = await Connect(fake, new SeestarSigner(other.ExportRSAPrivateKeyPem()));
        try
        {
            await Task.Delay(1500);
            Assert.True(c.IsConnected);
            Assert.False(c.IsAuthenticated);
        }
        finally { c.Disconnect(); }
    }

    [Fact]
    public async Task ErrorsTimeoutsAndSafety()
    {
        using var fake = new FakeSeestar();
        fake.Errors["scope_park"] = 207;
        fake.Silent.Add("scope_move_to_horizon");
        var c = await Connect(fake);
        try
        {
            await Assert.ThrowsAnyAsync<Exception>(() => c.Park());
            await Assert.ThrowsAnyAsync<Exception>(() => c.Send("scope_move_to_horizon", timeout: 1));
            await c.Send("get_device_state");
            c.GotoLimitsProvider = () => new GotoSafety.Limits(40.48, -3.36, 15, 30);
            var sun = Astro.Sun(DateTime.UtcNow);
            await Assert.ThrowsAsync<GotoBlockedException>(() => c.GotoTarget("Sol", sun.Ra, sun.Dec));
            Assert.Equal(0, fake.Count("iscope_start_view"));
        }
        finally { c.Disconnect(); }
    }

    [Fact]
    public async Task GotoRecentersWhenOffCentre()
    {
        using var fake = new FakeSeestar();
        var c = await Connect(fake);
        try
        {
            c.RecenterToleranceProvider = () => 2;
            fake.PointingOffsetsArcmin.Enqueue(3.0);
            fake.PointingOffsetsArcmin.Enqueue(0.5);
            var p = Astro.PrecessFromJ2000(2.53, 89.26, DateTime.UtcNow);
            Assert.True(await c.GotoAndWait("Polaris", p.Ra, p.Dec, timeout: 10));
            Assert.Equal(2, fake.Count("iscope_start_view"));
        }
        finally { c.Disconnect(); }
    }

    [Fact]
    public async Task DisconnectFailsPendingAndReconnects()
    {
        using var fake = new FakeSeestar();
        fake.DropOn.Add("reboot_simulado");
        var c = await Connect(fake);
        try
        {
            await Assert.ThrowsAnyAsync<Exception>(() => c.Send("reboot_simulado", timeout: 10));
            Assert.True(await WaitUntil(() => c.ConnectionCount >= 2 && c.IsConnected, 20));
        }
        finally { c.Disconnect(); }
    }

    [Fact]
    public async Task ImageStreamDeliversStackedFrame()
    {
        using var server = new FakeImageServer(64, 48);
        var stream = new ImageStream { Port = server.Port };
        RawFrame? got = null;
        stream.FrameReceived += f => got = f;
        stream.Connect("127.0.0.1");
        try
        {
            Assert.True(await WaitUntil(() => got is not null, 8));
            Assert.True(got!.Stacked);
            Assert.Equal(64, got.Width);
            Assert.Equal(48, got.Height);
        }
        finally { stream.Disconnect(); }
    }
}

public class ListsAndCometsTests
{
    private const string Mpc = """
    CK25A060  2025 11  8.5202  0.529814  0.995608  132.9562  108.0997  143.6634  20261108   8.6  4.0  C/2025 A6 (Lemmon)                                       MPEC 2026-U70
0012P         2024 04 21.2124  0.781960  0.954751  199.0367  255.8683   74.1442  20261108   5.0  6.0  12P/Pons-Brooks                                          MPEC 2026-TI5
    CK25K010  2025 10  8.4092  0.334370  1.000218  271.0354   97.5695  147.8676  20261108  12.2  4.0  C/2025 K1 (ATLAS)                                        MPEC 2026-TI5
0210P         2025 11 22.7082  0.524602  0.833994  345.9522   93.7986   10.2867  20261108  14.3  4.0  210P/Christensen                                         MPEC 2026-R26
""";

    [Fact]
    public void ExpandedCatalogAndCaldwell()
    {
        Assert.True(Catalog.Objects.Count > 1500);
        Assert.True(Catalog.Featured.Count < 300);
        Assert.Equal(Catalog.Objects.Count, Catalog.Objects.Select(o => Catalog.Normalize(o.Id)).Distinct().Count());
        Assert.Equal("NGC 869", Catalog.Find("C14")?.Id);
        Assert.Equal("NGC 2903", Catalog.Find("ngc2903")?.Id);
        Assert.All(ObservingLists.Entries(ObservingList.Caldwell), e => Assert.NotNull(e.Object));
        Assert.All(ObservingLists.Entries(ObservingList.Messier), e => Assert.NotNull(e.Object));
        Assert.Equal(14, Catalog.CaldwellNumber("NGC 869"));
    }

    [Theory]
    [InlineData("C/2025 A6 (Lemmon)", 182.01646, -35.22280, 5.1095, 5.8180)]
    [InlineData("12P/Pons-Brooks", 247.19108, -30.95300, 9.1006, 9.9759)]
    [InlineData("C/2025 K1 (ATLAS)", 19.97427, 45.29682, 5.6156, 4.7719)]
    [InlineData("210P/Christensen", 232.09659, -13.54302, 3.9361, 4.9102)]
    public void CometPositionsMatchJpl(string name, double ra, double dec, double r, double delta)
    {
        var o = Comets.Parse(Mpc).Single(x => x.Name == name);
        var p = Comets.Position(o, new DateTime(2026, 11, 8, 0, 0, 0, DateTimeKind.Utc));
        Assert.True(Astro.Separation(p.RaHours, p.DecDeg, ra / 15, dec) < 0.05);
        Assert.InRange(p.R, r - 0.005, r + 0.005);
        Assert.InRange(p.Delta, delta - 0.005, delta + 0.005);
    }

    [Fact]
    public void ParsesOnlyValidLines()
    {
        Assert.Equal(4, Comets.Parse(Mpc + "\nlínea rota\n" + new string('x', 200)).Count);
    }

    [Fact]
    public void MarathonWeekAndCsv()
    {
        var n = Astro.NightFor(new DateTime(2027, 4, 5, 12, 0, 0), 40.48, -3.36);
        var r = Marathon.Plan(n, 40.48, -3.36, 5, 3);
        Assert.Equal(110, r.Steps.Count + r.Missed.Count);
        Assert.True(r.Steps.Count >= 95);
        Assert.True(r.Steps.Zip(r.Steps.Skip(1)).All(p => p.First.Time <= p.Second.Time));
        Assert.Equal(100, WeekOutlook.Score(9, 0, 0, 0));
        Assert.True(WeekOutlook.Score(9, 90, 0, 0) < 10);
        var t = DateTime.UtcNow;
        var imaged = ObservingLists.Imaged([new ObservationRecord(Guid.NewGuid(), "NGC 869", t, t, 10, 10_000)]);
        var csv = ObservingLists.Csv(ObservingList.Caldwell, imaged, new Dictionary<string, double> { ["NGC 869"] = 300 });
        Assert.Contains("\"C14\",\"NGC 869\"", csv);
        Assert.Contains("\"sí\",\"300\"", csv);
    }
}

public class HorizonPlanTests
{
    [Fact]
    public void HorizonInterpolatesAndParses()
    {
        var h = new Horizon();
        Assert.True(h.IsFlat);
        h.Set(180, 40);
        Assert.Equal(40, h.AltitudeAt(180));
        Assert.Equal(20, h.AltitudeAt(185), 6);
        Assert.False(h.IsVisible(30, 180, 15));
        Assert.True(h.IsVisible(30, 90, 15));
        Assert.Equal(h.Altitudes, Horizon.Parse(h.Text())!.Altitudes);
        var other = Horizon.Parse("# x\n0;10\n90,30\n180\t10\n270 30\n")!;
        Assert.Equal(20, other.AltitudeAt(45), 6);
        Assert.Null(Horizon.Parse("10 20"));
    }

    [Fact]
    public void PlannerAndTimelineUseTheHorizon()
    {
        var night = Astro.NightFor(new DateTime(2026, 11, 8, 18, 0, 0), 40.48, -3.36);
        var m42 = Catalog.Find("M42")!;
        var open = Planner.Evaluate([m42], night, 40.48, -3.36, 15, (0.73, 1.29), []);
        var wall = new Horizon(Enumerable.Range(0, 36).Select(i => i is >= 9 and <= 27 ? 60.0 : 0));
        var blocked = Planner.Evaluate([m42], night, 40.48, -3.36, 15, (0.73, 1.29), [], wall);
        Assert.True(blocked[0].MinutesUsable < open[0].MinutesUsable / 2);
        var dusk = night.DuskStart!.Value;
        var a = new PlanItem { Name = "M31", RaHours = 0.71, DecDeg = 41.27, Minutes = 60, DoneSeconds = 1800 };
        var b = new PlanItem { Name = "M42", RaHours = 5.59, DecDeg = -5.39, Minutes = 30, NotBefore = dusk.AddHours(3) };
        var c = new PlanItem { Name = "M33", RaHours = 1.56, DecDeg = 30.66, Minutes = 900 };
        var slots = PlanTimeline.Schedule([a, b, c], night, dusk.AddHours(-1), new SkyLimit(15, Horizon.Flat), 40.48, -3.36);
        Assert.Equal(3, slots.Count);
        Assert.Equal(dusk, slots[0].Start);
        Assert.Equal(35, (slots[0].End - dusk).TotalMinutes, 3);
        Assert.True(slots[1].WaitMinutes > 60);
        Assert.True(slots[2].AfterDawn);
    }

    [Fact]
    public void ProjectsAndBackup()
    {
        var t = DateTime.UtcNow;
        var recs = new List<ObservationRecord>
        {
            new(Guid.NewGuid(), "M 31", t.AddDays(-3), t.AddDays(-3).AddHours(1), 360, 10_000),
            new(Guid.NewGuid(), "M31", t.AddHours(-1), t, 180, 10_000),
        };
        var p = ProjectStore.Progress("M31", recs);
        Assert.Equal(1.5, p.Hours, 3);
        Assert.Equal(2, p.Nights);
        Assert.Equal(120, ProjectStore.MinutesForTonight(10, 1.5));
        var s = new AppSettings { SiteName = "Casa", PemPath = "/yo/clave.pem" };
        s.Horizons["x"] = new Horizon(Enumerable.Repeat(12.0, 36));
        var json = BackupFile.Make(s, [new PlanItem { Name = "M42" }], [new Project { ObjectId = "M31" }], recs).Encoded();
        Assert.DoesNotContain("clave.pem", json);
        var back = BackupFile.Decode(json);
        Assert.Equal(2, back.History.Count);
        var restored = back.RestoredSettings(new AppSettings { PemPath = "/otra.pem" });
        Assert.Equal("Casa", restored.SiteName);
        Assert.Equal("/otra.pem", restored.PemPath);
        Assert.Equal(12, restored.Horizons["x"].Altitudes[0]);
        Assert.Throws<InvalidDataException>(() => BackupFile.Decode("{}"));
    }
}
