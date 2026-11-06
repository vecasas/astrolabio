using System.Text.Json.Nodes;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Imaging;
using Astrolabio.Core.Model;
using Astrolabio.Core.Protocol;
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
