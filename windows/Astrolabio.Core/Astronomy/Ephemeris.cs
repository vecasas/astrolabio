namespace Astrolabio.Core.Astronomy;

/// <summary>Salidas, puestas, fases lunares y datos de los planetas (port de Ephemeris.swift).</summary>
public static class Ephemeris
{
    public sealed record RiseSet(DateTime? Rise, DateTime? Transit, DateTime? Set, double MaxAltitude, bool AlwaysUp, bool NeverUp);

    public static RiseSet Compute(DateTime startUtc, double hours, double stepSeconds, double h0, Func<DateTime, double> altitude)
    {
        DateTime? rise = null, set = null; DateTime transit = startUtc;
        var t = startUtc; var prev = altitude(t); var maxAlt = prev;
        bool always = prev >= h0, never = prev < h0;
        var end = startUtc.AddHours(hours);
        while (t < end)
        {
            var next = t.AddSeconds(stepSeconds);
            var alt = altitude(next);
            if (alt > maxAlt) { maxAlt = alt; transit = next; }
            if (alt >= h0) never = false; else always = false;
            if (prev < h0 && alt >= h0 && rise is null) rise = t.AddSeconds(stepSeconds * (h0 - prev) / (alt - prev));
            if (prev >= h0 && alt < h0 && set is null) set = t.AddSeconds(stepSeconds * (prev - h0) / (prev - alt));
            prev = alt; t = next;
        }
        return new RiseSet(rise, transit, set, maxAlt, always, never);
    }

    public static Func<DateTime, double> FixedAltitude(double raJ2000, double decJ2000, double lat, double lon)
    {
        var now = Astro.PrecessFromJ2000(raJ2000, decJ2000, DateTime.UtcNow);
        return t => Astro.AltAz(now.Ra, now.Dec, t, lat, lon).Alt;
    }

    public static Func<DateTime, double> MoonAltitude(double lat, double lon) =>
        t => { var m = Astro.Moon(t); return Astro.AltAz(m.Ra, m.Dec, t, lat, lon).Alt; };

    public static Func<DateTime, double> PlanetAltitude(string name, double lat, double lon) =>
        t => Astro.Planet(name, t) is { } p ? Astro.AltAz(p.Ra, p.Dec, t, lat, lon).Alt : -90;

    public static double MoonElongation(DateTime t) => Astro.Norm360(Astro.Moon(t).Lambda - Astro.Sun(t).Lambda);

    public static readonly (double Angle, string Name)[] PhaseKinds =
        [(0, "Luna nueva"), (90, "Cuarto creciente"), (180, "Luna llena"), (270, "Cuarto menguante")];

    public static List<(string Name, DateTime Date)> NextPhases(DateTime afterUtc, int count = 4)
    {
        var res = new List<(string, DateTime)>();
        var t = afterUtc; var prev = MoonElongation(t);
        while (res.Count < count && t < afterUtc.AddDays(40))
        {
            var next = t.AddHours(3); var e = MoonElongation(next);
            foreach (var (target, name) in PhaseKinds)
            {
                double Diff(double x) { var d = x - target; while (d > 180) d -= 360; while (d <= -180) d += 360; return d; }
                double d0 = Diff(prev), d1 = Diff(e);
                if (d0 < 0 && d1 >= 0 && Math.Abs(d1 - d0) < 90)
                {
                    DateTime a = t, b = next;
                    for (var k = 0; k < 20; k++) { var m = a + (b - a) / 2; if (Diff(MoonElongation(m)) < 0) a = m; else b = m; }
                    res.Add((name, b));
                }
            }
            prev = e; t = next;
        }
        return res.OrderBy(r => r.Item2).Take(count).ToList();
    }

    public static double MoonDistanceKm(DateTime t)
    {
        var T = (Astro.JulianDay(t) - 2451545.0) / 36525;
        double mp = (134.9633964 + 477198.8675055 * T) * Astro.Deg, d = (297.8501921 + 445267.1114034 * T) * Astro.Deg, m = (357.5291092 + 35999.0502909 * T) * Astro.Deg;
        return 385000.56 - 20905.355 * Math.Cos(mp) - 3699.111 * Math.Cos(2 * d - mp) - 2955.968 * Math.Cos(2 * d) - 569.925 * Math.Cos(2 * mp) + 48.888 * Math.Cos(m);
    }

    public static readonly Dictionary<string, (double DiameterKm, string Note)> PlanetInfo = new()
    {
        ["Mercurio"] = (4879, "Siempre cerca del Sol: búscalo en el crepúsculo."),
        ["Venus"] = (12104, "Muestra fases como la Luna."),
        ["Marte"] = (6779, "Mejor cerca de la oposición, cuando se ve más grande."),
        ["Júpiter"] = (139820, "Bandas de nubes y las cuatro lunas galileanas."),
        ["Saturno"] = (116460, "Los anillos se distinguen incluso con el Seestar."),
        ["Urano"] = (50724, "Un pequeño disco verdoso."),
        ["Neptuno"] = (49244, "Un punto azulado: pide un apilado largo."),
    };

    public static double? DiameterArcsec(string name, double au) =>
        PlanetInfo.TryGetValue(name, out var i) && au > 0 ? 2 * Math.Atan(i.DiameterKm / 2 / (au * 149_597_870.7)) * Astro.Rad * 3600 : null;

    public static (double SunDistance, double PhaseAngle, double Elongation)? Geometry(string name, DateTime t)
    {
        if (Astro.Planet(name, t) is not { } p) return null;
        var s = Astro.Sun(t);
        var elong = Astro.Separation(p.Ra, p.Dec, s.Ra, s.Dec);
        var delta = p.Distance;
        var r = Math.Sqrt(Math.Max(0.01, 1 + delta * delta - 2 * delta * Math.Cos(elong * Astro.Deg)));
        var cosPhase = (r * r + delta * delta - 1) / (2 * r * delta);
        return (r, Math.Acos(Math.Clamp(cosPhase, -1, 1)) * Astro.Rad, elong);
    }

    public static double? Magnitude(string name, DateTime t)
    {
        if (Astro.Planet(name, t) is not { } p || Geometry(name, t) is not { } g) return null;
        var k = 5 * Math.Log10(g.SunDistance * p.Distance); var i = g.PhaseAngle;
        return name switch
        {
            "Mercurio" => -0.42 + k + 0.038 * i - 0.000273 * i * i + 0.000002 * i * i * i,
            "Venus" => -4.40 + k + 0.0009 * i + 0.000239 * i * i - 0.00000065 * i * i * i,
            "Marte" => -1.52 + k + 0.016 * i, "Júpiter" => -9.40 + k + 0.005 * i, "Saturno" => -8.88 + k + 0.044 * i,
            "Urano" => -7.19 + k, "Neptuno" => -6.87 + k, _ => null,
        };
    }
}
