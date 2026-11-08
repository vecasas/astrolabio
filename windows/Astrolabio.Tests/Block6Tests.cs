using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Xunit;

namespace Astrolabio.Tests;

// Las mismas comprobaciones que SGP4Tests.swift y Block6Tests.swift.
public class SatelliteTests
{
    const string L1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753";
    const string L2 = "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667";
    public const string Iss1 = "1 25544U 98067A   26312.17541007  .00012511  00000+0  23266-3 0  9990";
    public const string Iss2 = "2 25544  51.6320 307.5621 0007219   1.6306 358.4705 15.49256954594075";

    [Fact]
    public void ParsesTle()
    {
        var t = Tle.Parse("VANGUARD 1", L1, L2)!;
        Assert.Equal(0.1859667, t.Ecc, 9);
        Assert.Equal(0.28098e-4, t.Bstar, 12);
        Assert.Null(Tle.Parse("x", L1.Replace("4753", "4754"), L2));
        Assert.Single(Tle.ParseList($"VANGUARD 1\n{L1}\n{L2}\nbasura\n"));
    }

    [Theory]
    [InlineData(0.0, 7022.46529266, -1400.08296755, 0.03995155, 1.893841015, 6.405893759, 4.534807250)]
    [InlineData(360.0, -7154.03120202, -3783.17682504, -3536.19412294, 4.741887409, -4.151817765, -2.093935425)]
    public void MatchesValladoVectors(double min, double rx, double ry, double rz, double vx, double vy, double vz)
    {
        var s = Sgp4.Create(Tle.Parse("VANGUARD 1", L1, L2)!)!;
        var o = s.Propagate(min)!.Value;
        Assert.True(Math.Sqrt(Math.Pow(o.R.X - rx, 2) + Math.Pow(o.R.Y - ry, 2) + Math.Pow(o.R.Z - rz, 2)) < 1.0);
        Assert.True(Math.Sqrt(Math.Pow(o.V.X - vx, 2) + Math.Pow(o.V.Y - vy, 2) + Math.Pow(o.V.Z - vz, 2)) < 0.001);
    }

    /// <summary>Pasos de la ISS sobre Madrid frente a Skyfield (8–13 nov 2026).</summary>
    static readonly (double Rise, double Alt, double Set)[] Reference = [ (1794101573, 24.7, 1794101915), (1794107364, 50.9, 1794107759), (1794167515, 66.8, 1794167913), (1794173377, 21.6, 1794173698), (1794179314, 12.3, 1794179492), (1794185121, 19.0, 1794185422), (1794190899, 89.7, 1794191305), (1794251070, 36.6, 1794251442), (1794256887, 29.1, 1794257245), (1794262825, 12.9, 1794263021), (1794268668, 15.6, 1794268923), (1794274439, 53.2, 1794274837), (1794280291, 17.2, 1794280567), (1794334644, 21.2, 1794334956), (1794340403, 43.0, 1794340789), (1794346326, 14.4, 1794346560), (1794352210, 13.5, 1794352422), (1794357982, 34.2, 1794358357), (1794363795, 29.1, 1794364152), (1794418258, 12.3, 1794418433), (1794423928, 71.5, 1794424328), (1794429824, 17.2, 1794430102), (1794435743, 12.4, 1794435924), (1794441525, 24.4, 1794441866), (1794447316, 51.7, 1794447710), (1794507464, 65.5, 1794507860), (1794513324, 21.7, 1794513645), (1794519262, 12.2, 1794519437), (1794525068, 18.8, 1794525367) ];

    [Fact]
    public void IssPassesMatchReferenceWithinAMinute()
    {
        var t = Tle.Parse("ISS (ZARYA)", Iss1, Iss2)!;
        var start = DateTime.UnixEpoch.AddSeconds(1794096000);
        var ours = Satellites.Passes(t, start, 5, 40.4168, -3.7038, onlyVisible: false);
        Assert.Equal(Reference.Length, ours.Count);
        foreach (var (rise, alt, set) in Reference)
        {
            var m = ours.MinBy(p => Math.Abs((p.Rise - DateTime.UnixEpoch).TotalSeconds - rise))!;
            Assert.True(Math.Abs((m.Rise - DateTime.UnixEpoch).TotalSeconds - rise) < 60);
            Assert.True(Math.Abs((m.Set - DateTime.UnixEpoch).TotalSeconds - set) < 60);
            Assert.True(Math.Abs(m.MaxAltitude - alt) < 1.5);
        }
        var visible = Satellites.Passes(t, start, 5, 40.4168, -3.7038);
        Assert.True(visible.Count < ours.Count && visible.All(p => p.Sunlit));
    }

    [Fact]
    public void CrossingIsDetected()
    {
        var t = Tle.Parse("ISS (ZARYA)", Iss1, Iss2)!;
        var peak = DateTime.UnixEpoch.AddSeconds(1794191102);
        var r = Sgp4.Create(t)!.Position(peak)!.Value;
        var aa = Satellites.AltAz(r, peak, 40.4168, -3.7038);
        Assert.True(aa.Alt > 85);
        // De altura/acimut a AR/Dec J2000 (corrigiendo la precesión).
        double d = Astro.Deg, lat = 40.4168;
        var dec = Math.Asin(Math.Sin(aa.Alt * d) * Math.Sin(lat * d) + Math.Cos(aa.Alt * d) * Math.Cos(lat * d) * Math.Cos(aa.Az * d));
        var h = Math.Atan2(-Math.Sin(aa.Az * d) * Math.Cos(aa.Alt * d), Math.Sin(aa.Alt * d) * Math.Cos(lat * d) - Math.Cos(aa.Alt * d) * Math.Sin(lat * d) * Math.Cos(aa.Az * d));
        var raDate = Astro.Norm360(Astro.LocalSiderealTime(peak, -3.7038) - h / d) / 15;
        double ra = raDate, de = dec / d;
        for (var k = 0; k < 3; k++) { var p = Astro.PrecessFromJ2000(ra, de, peak); ra -= p.Ra - raDate; de -= p.Dec - dec / d; }
        var c = Satellites.ClosestApproach(t, ra, de, peak.AddMinutes(-10), peak.AddMinutes(10), 40.4168, -3.7038)!.Value;
        Assert.True(c.Sep < 0.5 && Math.Abs((c.At - peak).TotalSeconds) < 5);
        Assert.Empty(Satellites.Crossings([t], ra + 6, -de, peak.AddMinutes(-10), peak.AddMinutes(10), 40.4168, -3.7038));
    }

    [Fact]
    public void StoreAcceptsOnlyCelestrakHttps()
    {
        var text = System.Text.Encoding.UTF8.GetBytes($"ISS (ZARYA)\n{Iss1}\n{Iss2}\n");
        Assert.NotNull(SatelliteStore.Accept(text, new Uri("https://celestrak.org/x")));
        Assert.Null(SatelliteStore.Accept(text, new Uri("http://celestrak.org/x")));
        Assert.Null(SatelliteStore.Accept(text, new Uri("https://evil.example/x")));
        Assert.Null(SatelliteStore.Accept(new byte[SatelliteStore.MaxBytes + 1], new Uri("https://celestrak.org/x")));
        Assert.Null(SatelliteStore.Accept("<html>"u8.ToArray(), new Uri("https://celestrak.org/x")));
        Assert.Single(SatelliteStore.Merge(Tle.ParseList($"X\n{Iss1}\n{Iss2}\nISS (ZARYA)\n{Iss1}\n{Iss2}\n")));
    }
}

[Collection("Idioma")]
public class MoonAndEventsTests
{
    [Fact]
    public void LibrationMatchesMeeus()
    {
        var g = MoonFeatures.Geometry(new DateTime(1992, 4, 12, 0, 0, 0, DateTimeKind.Utc));
        Assert.True(Math.Abs(g.L - -1.206) < 0.6 && Math.Abs(g.B - 4.194) < 0.5);
        Assert.True(Math.Abs(g.L0 - 67.89) < 0.5 && Math.Abs(g.B0 - 1.46) < 0.2);
    }

    [Fact]
    public void TerminatorAndProjection()
    {
        var fq = Ephemeris.NextPhases(new DateTime(2026, 11, 1, 0, 0, 0, DateTimeKind.Utc)).First(p => p.Name == "Cuarto creciente").Date;
        var g = MoonFeatures.Geometry(fq);
        MoonFeature F(string n) => MoonFeatures.All.First(f => f.Name == n);
        Assert.True(Math.Abs(MoonFeatures.SunAltitude(F("Ptolemaeus"), g)) < 8);
        Assert.Equal(MoonLight.Lit, MoonFeatures.Light(F("Mare Crisium"), g));
        Assert.Equal(MoonLight.Dark, MoonFeatures.Light(F("Grimaldi"), g));
        Assert.True(MoonFeatures.Project(F("Mare Crisium"), g).X > 0.6 && MoonFeatures.Project(F("Grimaldi"), g).X < -0.8);
        Assert.True(MoonFeatures.Project(F("Plato"), g).Y > 0.7 && MoonFeatures.Project(F("Tycho"), g).Y < -0.6);
        Assert.NotEmpty(MoonFeatures.BestNow(g));
        Assert.True(MoonFeatures.All.Length >= 60);
        Assert.Equal(MoonFeatures.All.Length, MoonFeatures.All.Select(f => f.Name).Distinct().Count());
    }

    [Fact]
    public void FindsShowersPhasesAndConjunctions()
    {
        var ev = SkyEvents.Upcoming(new DateTime(2026, 11, 8, 0, 0, 0, DateTimeKind.Utc), 40.4, -3.7);
        Assert.Contains(ev, e => e.Kind == SkyEventKind.Meteors && e.Title == Strings.T("Gemínidas"));
        Assert.Contains(ev, e => e.Kind == SkyEventKind.Meteors && e.Title == Strings.T("Leónidas"));
        Assert.True(ev.Count(e => e.Kind == SkyEventKind.Phase) >= 5);
        Assert.Contains(ev, e => e.Kind == SkyEventKind.Conjunction);
        Assert.True(ev.Zip(ev.Skip(1)).All(p => p.First.Date <= p.Second.Date));
    }

    [Fact]
    public void MinimaFindsParabolaVertex()
    {
        var t0 = DateTime.UnixEpoch;
        var m = SkyEvents.Minima(t0, t0.AddSeconds(100), 10, 5, d => { var x = (d - t0).TotalSeconds - 43; return 1 + x * x / 100; });
        Assert.Single(m);
        Assert.True(Math.Abs((m[0].Date - t0).TotalSeconds - 43) < 0.5 && Math.Abs(m[0].Value - 1) < 0.01);
    }
}
