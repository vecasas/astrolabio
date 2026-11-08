namespace Astrolabio.Core.Astronomy;

public enum SkyEventKind { Meteors, Conjunction, Pair, Phase, Opposition, Elongation, Comet }
public enum SkyEventTag { FitsField, NakedEye, DarkSky, MoonBright, Twilight, LowSky }

public sealed record SkyEvent(SkyEventKind Kind, DateTime Date, string Title, string Detail, List<SkyEventTag> Tags)
{
    public static string TagName(SkyEventTag t) => t switch
    {
        SkyEventTag.FitsField => Strings.T("Cabe en el campo del Seestar"),
        SkyEventTag.NakedEye => Strings.T("A simple vista"),
        SkyEventTag.DarkSky => Strings.T("Sin Luna"),
        SkyEventTag.MoonBright => Strings.T("Luna brillante"),
        SkyEventTag.Twilight => Strings.T("En el crepúsculo"),
        _ => Strings.T("Bajo en el cielo"),
    };
    public static bool IsGood(SkyEventTag t) => t is SkyEventTag.FitsField or SkyEventTag.NakedEye or SkyEventTag.DarkSky;
    public static string KindName(SkyEventKind k) => k switch
    {
        SkyEventKind.Meteors => Strings.T("Meteoros"),
        SkyEventKind.Conjunction => Strings.T("Luna y planetas"),
        SkyEventKind.Pair => Strings.T("Parejas de planetas"),
        SkyEventKind.Phase => Strings.T("Fases"),
        SkyEventKind.Opposition => Strings.T("Oposiciones"),
        SkyEventKind.Elongation => Strings.T("Elongaciones"),
        _ => Strings.T("Cometas"),
    };
}

/// <summary>Port de SkyEvents.swift: lo que pasa en el cielo en las próximas semanas. Fechas en UTC.</summary>
public static class SkyEvents
{
    public static readonly (string Name, int Month, int Day, int Zhr, string Radiant)[] Showers =
    [
        ("Cuadrántidas", 1, 4, 110, "Bootes"), ("Líridas", 4, 22, 18, "Lyra"), ("Eta Acuáridas", 5, 6, 50, "Aquarius"),
        ("Delta Acuáridas", 7, 30, 25, "Aquarius"), ("Perseidas", 8, 12, 100, "Perseus"), ("Dracónidas", 10, 8, 10, "Draco"),
        ("Oriónidas", 10, 21, 20, "Orion"), ("Táuridas", 11, 5, 5, "Taurus"), ("Leónidas", 11, 17, 15, "Leo"),
        ("Gemínidas", 12, 14, 150, "Gemini"), ("Úrsidas", 12, 22, 10, "Ursa Minor"),
    ];
    public const double FieldDegrees = 1.29;

    public static List<SkyEvent> Upcoming(DateTime startUtc, double lat, double lon, int days = 42, IEnumerable<CometOrbit>? comets = null)
    {
        var end = startUtc.AddDays(days);
        var res = new List<SkyEvent>();
        res.AddRange(MeteorShowers(startUtc, end, lat, lon));
        res.AddRange(Phases(startUtc, end));
        res.AddRange(MoonConjunctions(startUtc, end, lat, lon));
        res.AddRange(PlanetPairs(startUtc, end, lat, lon));
        res.AddRange(PlanetMilestones(startUtc, end));
        res.AddRange(BrightComets(comets ?? [], startUtc, end, lat, lon));
        return res.OrderBy(e => e.Date).ToList();
    }

    public static List<SkyEvent> MeteorShowers(DateTime start, DateTime end, double lat, double lon)
    {
        var res = new List<SkyEvent>();
        var y0 = start.ToLocalTime().Year;
        foreach (var year in new[] { y0, y0 + 1 })
            foreach (var s in Showers)
            {
                var d = new DateTime(year, s.Month, s.Day, 2, 0, 0, DateTimeKind.Local).ToUniversalTime();
                if (d < start.AddDays(-1) || d > end) continue;
                var m = Astro.Moon(d);
                var moonUp = Astro.AltAz(m.Ra, m.Dec, d, lat, lon).Alt > 0;
                var tags = new List<SkyEventTag> { SkyEventTag.NakedEye, m.Illumination >= 0.35 && moonUp ? SkyEventTag.MoonBright : SkyEventTag.DarkSky };
                res.Add(new SkyEvent(SkyEventKind.Meteors, d, Strings.T(s.Name),
                    Strings.T("Máximo de unos %d meteoros por hora con cielo ideal; radiante en %@. Mejor de madrugada, a simple vista o con una cámara de gran angular: el Seestar tiene un campo demasiado pequeño.", s.Zhr, s.Radiant), tags));
            }
        return res;
    }

    public static List<SkyEvent> Phases(DateTime start, DateTime end) =>
        Ephemeris.NextPhases(start, 8).Where(p => p.Date <= end).Select(p =>
        {
            var tags = p.Name == "Luna nueva" ? new List<SkyEventTag> { SkyEventTag.DarkSky }
                     : p.Name == "Luna llena" ? [SkyEventTag.MoonBright] : new List<SkyEventTag>();
            var detail = p.Name switch
            {
                "Luna nueva" => Strings.T("Las noches más oscuras del mes: lo mejor para galaxias y nebulosas débiles."),
                "Luna llena" => Strings.T("La Luna ilumina todo el cielo: buena noche para la Luna, los planetas y las estrellas dobles."),
                _ => Strings.T("Con la Luna a medias el terminador muestra el relieve: buen momento para fotografiarla."),
            };
            return new SkyEvent(SkyEventKind.Phase, p.Date, Strings.T(p.Name), detail, tags);
        }).ToList();

    /// <summary>Mínimos locales (afinados con una parábola) por debajo de <paramref name="limit"/>.</summary>
    public static List<(DateTime Date, double Value)> Minima(DateTime start, DateTime end, double stepSeconds, double limit, Func<DateTime, double> f)
    {
        var res = new List<(DateTime, double)>();
        var t = start;
        double a = f(t), b = f(t.AddSeconds(stepSeconds));
        while (t.AddSeconds(2 * stepSeconds) <= end)
        {
            var c = f(t.AddSeconds(2 * stepSeconds));
            if (b <= a && b < c && b < limit)
            {
                var denom = a - 2 * b + c;
                var off = denom > 0 ? 0.5 * (a - c) / denom : 0;
                res.Add((t.AddSeconds(stepSeconds * (1 + Math.Clamp(off, -1, 1))), Math.Max(0, b - 0.25 * (a - c) * off)));
            }
            a = b; b = c; t = t.AddSeconds(stepSeconds);
        }
        return res;
    }

    public static double BestDarkAltitude(double ra, double dec, DateTime near, double lat, double lon)
    {
        var best = -90.0;
        for (var t = near.AddHours(-10); t <= near.AddHours(10); t = t.AddMinutes(30))
            if (Astro.SunAltitude(t, lat, lon) < -6) best = Math.Max(best, Astro.AltAz(ra, dec, t, lat, lon).Alt);
        return best;
    }

    public static List<SkyEvent> MoonConjunctions(DateTime start, DateTime end, double lat, double lon)
    {
        var res = new List<SkyEvent>();
        foreach (var name in Astro.PlanetNames.Where(n => n != "Neptuno"))
        {
            double Sep(DateTime d)
            {
                if (Astro.Planet(name, d) is not { } p) return 180;
                var m = Astro.Moon(d);
                return Astro.Separation(p.Ra, p.Dec, m.Ra, m.Dec);
            }
            foreach (var m in Minima(start, end, 3600, 5, Sep))
            {
                if (Astro.Planet(name, m.Date) is not { } p || Ephemeris.Geometry(name, m.Date) is not { } g || g.Elongation < 12) continue;
                var alt = BestDarkAltitude(p.Ra, p.Dec, m.Date, lat, lon);
                var tags = new List<SkyEventTag>();
                if (m.Value < FieldDegrees * 0.8) tags.Add(SkyEventTag.FitsField);
                tags.Add(SkyEventTag.NakedEye);
                if (g.Elongation < 30) tags.Add(SkyEventTag.Twilight);
                if (alt < 15) tags.Add(SkyEventTag.LowSky);
                res.Add(new SkyEvent(SkyEventKind.Conjunction, m.Date, Strings.T("La Luna y %@", Strings.T(name)),
                                     Strings.T("Separación mínima de %.1f°.", m.Value), tags));
            }
        }
        return res;
    }

    public static List<SkyEvent> PlanetPairs(DateTime start, DateTime end, double lat, double lon)
    {
        var res = new List<SkyEvent>();
        var names = Astro.PlanetNames;
        for (var i = 0; i < names.Length; i++)
            for (var j = i + 1; j < names.Length; j++)
            {
                string a = names[i], b = names[j];
                double Sep(DateTime d) => Astro.Planet(a, d) is { } p && Astro.Planet(b, d) is { } q ? Astro.Separation(p.Ra, p.Dec, q.Ra, q.Dec) : 180;
                foreach (var m in Minima(start, end, 6 * 3600, 3, Sep))
                {
                    if (Astro.Planet(a, m.Date) is not { } p || Ephemeris.Geometry(a, m.Date) is not { } g || g.Elongation < 12) continue;
                    var alt = BestDarkAltitude(p.Ra, p.Dec, m.Date, lat, lon);
                    var tags = new List<SkyEventTag>();
                    if (m.Value < FieldDegrees * 0.8) tags.Add(SkyEventTag.FitsField);
                    if (new[] { a, b }.All(n => (Ephemeris.Magnitude(n, m.Date) ?? 9) < 6)) tags.Add(SkyEventTag.NakedEye);
                    if (g.Elongation < 30) tags.Add(SkyEventTag.Twilight);
                    if (alt < 15) tags.Add(SkyEventTag.LowSky);
                    res.Add(new SkyEvent(SkyEventKind.Pair, m.Date, Strings.T("%1$@ y %2$@", Strings.T(a), Strings.T(b)),
                                         Strings.T("Separación mínima de %.1f°.", m.Value), tags));
                }
            }
        return res;
    }

    public static List<SkyEvent> PlanetMilestones(DateTime start, DateTime end)
    {
        var res = new List<SkyEvent>();
        foreach (var name in Astro.PlanetNames)
        {
            var inner = name is "Mercurio" or "Venus";
            foreach (var m in Minima(start, end, 12 * 3600, 0, d => -(Ephemeris.Geometry(name, d)?.Elongation ?? 0)))
            {
                var e = -m.Value;
                if (inner)
                {
                    if (e <= 15) continue;
                    var east = Astro.Norm360((Astro.Planet(name, m.Date)?.Ra ?? 0) * 15 - Astro.Sun(m.Date).Ra * 15) < 180;
                    res.Add(new SkyEvent(SkyEventKind.Elongation, m.Date, Strings.T("Máxima elongación de %@", Strings.T(name)),
                        Strings.T("%1$.0f° del Sol, visible %2$@.", e, east ? Strings.T("al anochecer") : Strings.T("al amanecer")),
                        [SkyEventTag.NakedEye, SkyEventTag.Twilight]));
                }
                else if (e > 175)
                    res.Add(new SkyEvent(SkyEventKind.Opposition, m.Date, Strings.T("Oposición de %@", Strings.T(name)),
                        Strings.T("Toda la noche en el cielo y en su máximo brillo y tamaño: el mejor momento del año para fotografiarlo."),
                        (Ephemeris.Magnitude(name, m.Date) ?? 9) < 6 ? [SkyEventTag.NakedEye] : []));
            }
        }
        return res;
    }

    public static List<SkyEvent> BrightComets(IEnumerable<CometOrbit> orbits, DateTime start, DateTime end, double lat, double lon, double maxMagnitude = 9)
    {
        var res = new List<SkyEvent>();
        foreach (var o in orbits)
        {
            (DateTime, CometPosition)? best = null;
            for (var t = start; t <= end; t = t.AddDays(1))
            {
                var p = Comets.Position(o, t);
                if (double.IsFinite(p.Magnitude) && (best is null || p.Magnitude < best.Value.Item2.Magnitude)) best = (t, p);
            }
            if (best is not { } b || b.Item2.Magnitude > maxMagnitude) continue;
            var alt = BestDarkAltitude(b.Item2.RaHours, b.Item2.DecDeg, b.Item1, lat, lon);
            if (alt <= 0) continue;
            var tags = new List<SkyEventTag>();
            if (b.Item2.Magnitude < 6) tags.Add(SkyEventTag.NakedEye);
            if (alt < 15) tags.Add(SkyEventTag.LowSky);
            res.Add(new SkyEvent(SkyEventKind.Comet, b.Item1, o.Name, Strings.T("Magnitud prevista %.1f en su mejor momento del periodo.", b.Item2.Magnitude), tags));
        }
        return res.OrderBy(e => e.Date).Take(8).ToList();
    }
}
