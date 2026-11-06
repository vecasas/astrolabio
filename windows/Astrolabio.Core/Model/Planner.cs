using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Services;

namespace Astrolabio.Core.Model;

public sealed record FrameFit(string Kind, int Columns = 1, int Rows = 1)
{
    public static readonly FrameFit Small = new("small"), Good = new("good");
    public string Label => Kind switch
    {
        "small" => Strings.T("Pequeño"), "good" => Strings.T("Cabe bien"), _ => Strings.T("Mosaico %@×%@", Columns, Rows),
    };
    public bool IsMosaic => Kind == "mosaic";
}

public sealed record TargetForecast(DeepSkyObject Object, double MinutesUsable, double MaxAltitude, DateTime? BestTime,
    DateTime? WindowStart, DateTime? WindowEnd, double MoonSeparation, double? MeanCloud, FrameFit Fit, double Score);

/// <summary>Ordena el catálogo para una noche (port de Planner.swift).</summary>
public static class Planner
{
    public static List<TargetForecast> Evaluate(IEnumerable<DeepSkyObject> objects, Astro.Night night, double lat, double lon,
        double minAltitude, (double W, double H) fov, IReadOnlyList<WeatherHour> weather)
    {
        if (night.DuskStart is not DateTime start || night.DawnEnd is not DateTime end || end <= start) return [];
        const double step = 600;
        var times = new List<DateTime>();
        for (var t = start; t <= end; t = t.AddSeconds(step)) times.Add(t);
        var mid = start + (end - start) / 2;
        var moon = Astro.Moon(mid);
        var moonUp = times.Count(t => { var m = Astro.Moon(t); return Astro.AltAz(m.Ra, m.Dec, t, lat, lon).Alt > 0; }) / (double)Math.Max(1, times.Count);
        var clouds = times.Select(t => WeatherService.CloudCover(t, weather)).ToArray();
        var res = new List<TargetForecast>();
        foreach (var obj in objects)
        {
            var now = Astro.PrecessFromJ2000(obj.RaHours, obj.DecDeg, mid);
            double usable = 0, maxAlt = -90, cloudSum = 0, cloudN = 0;
            DateTime? best = null, first = null, last = null;
            for (var i = 0; i < times.Count; i++)
            {
                var alt = Astro.AltAz(now.Ra, now.Dec, times[i], lat, lon).Alt;
                if (alt > maxAlt) { maxAlt = alt; best = times[i]; }
                if (alt >= minAltitude)
                {
                    usable += step / 60;
                    first ??= times[i]; last = times[i];
                    if (clouds[i] is double c) { cloudSum += c; cloudN++; }
                }
            }
            var sep = Astro.Separation(now.Ra, now.Dec, moon.Ra, moon.Dec);
            double? meanCloud = cloudN > 0 ? cloudSum / cloudN : null;
            var fit = FrameFitFor(obj.SizeArcmin, fov);
            var score = Math.Min(usable, 360) / 360 * 60 + Math.Max(0, maxAlt - minAltitude) / (90 - minAltitude) * 15;
            var sensitivity = obj.Kind switch { ObjectKind.Galaxy => 1.0, ObjectKind.Planetary or ObjectKind.Snr or ObjectKind.Nebula => 0.5, ObjectKind.Globular => 0.4, _ => 0.2 };
            var moonFactor = moon.Illumination * moonUp * (sep < 30 ? 1 : sep < 60 ? 0.6 : 0.3);
            score *= 1 - sensitivity * moonFactor * 0.7;
            if (meanCloud is double mc) score *= 1 - mc / 100 * 0.9;
            score *= fit.Kind switch { "small" => obj.SizeArcmin < 1.5 ? 0.6 : 0.8, "good" => 1, _ => 0.85 };
            if (obj.Magnitude > 10.5) score *= 0.85;
            if (usable == 0) score = 0;
            res.Add(new TargetForecast(obj, usable, maxAlt, best, first, last, sep, meanCloud, fit, score));
        }
        return res.OrderByDescending(f => f.Score).ToList();
    }

    public static FrameFit FrameFitFor(double sizeArcmin, (double W, double H) fov)
    {
        var size = sizeArcmin / 60;
        if (size < fov.W * 0.12) return FrameFit.Small;
        if (size <= fov.H * 0.95) return FrameFit.Good;
        return new FrameFit("mosaic", Math.Clamp((int)Math.Ceiling(size / (fov.W * 0.85)), 1, 3), Math.Clamp((int)Math.Ceiling(size / (fov.H * 0.85)), 1, 3));
    }

    public static List<(string Label, double Ra, double Dec)> MosaicPanels(double centerRA, double centerDec, int columns, int rows, double overlap, (double W, double H) fov)
    {
        double stepDec = fov.H * (1 - overlap / 100), stepRa = fov.W * (1 - overlap / 100);
        var res = new List<(string, double, double)>();
        for (var r = 0; r < rows; r++)
        {
            var dec = centerDec + (r - (rows - 1) / 2.0) * stepDec;
            var cosd = Math.Max(0.05, Math.Cos(dec * Astro.Deg));
            for (var c = 0; c < columns; c++)
            {
                var ra = centerRA + (c - (columns - 1) / 2.0) * stepRa / cosd / 15;
                if (ra < 0) ra += 24; if (ra >= 24) ra -= 24;
                res.Add(($"{c + 1}{r + 1}", ra, Math.Clamp(dec, -89.9, 89.9)));
            }
        }
        return res;
    }
}

/// <summary>Recomendación de captura: duración, exposición, ganancia y filtro LP.</summary>
public sealed record CaptureAdvice(double Minutes, int ExposureMs, int Gain, bool LpFilter, double RemainingMinutes, double AltitudeNow, List<string> Reasons)
{
    public static CaptureAdvice Make(DeepSkyObject obj, double lat, double lon, double minAltitude, Astro.Night? night, int gain, DateTime? nowUtc = null)
    {
        var now = nowUtc ?? DateTime.UtcNow;
        var alt = Ephemeris.FixedAltitude(obj.RaHours, obj.DecDeg, lat, lon);
        var a0 = alt(now);
        var end = night?.DawnEnd is DateTime d && d > now ? d : now.AddHours(8);
        double remaining = 0;
        for (var t = now; t < end && alt(t) >= minAltitude; t = t.AddMinutes(5)) remaining += 5;
        var lp = obj.Kind.WantsLP();
        var reasons = new List<string>();
        int exp;
        if (obj.Magnitude <= 5.5 || (obj.Kind == ObjectKind.Open && obj.Magnitude <= 7))
        { exp = 10_000; reasons.Add(Strings.T("Es muy brillante (mag %.1f): 10 s evitan que las estrellas se saturen.", obj.Magnitude)); }
        else if (obj.Magnitude <= 8.5 && !lp)
        { exp = 20_000; reasons.Add(Strings.T("Brillo intermedio (mag %.1f): 20 s por toma.", obj.Magnitude)); }
        else
        {
            exp = 30_000;
            reasons.Add(lp ? Strings.T("Con el filtro LP llega menos luz: mejor tomas largas de 30 s.") : Strings.T("Es débil (mag %.1f): tomas largas de 30 s.", obj.Magnitude));
        }
        reasons.Add(lp ? Strings.T("%@: el filtro antipolución (LP) realza el gas y oscurece el fondo.", obj.Kind.Label())
                       : Strings.T("%@: sin filtro LP, para conservar el color de las estrellas.", obj.Kind.Label()));
        var minutes = Math.Max(20, Math.Round(Math.Min(remaining * 0.8, 120) / 10) * 10);
        reasons.Add(a0 < minAltitude
            ? Strings.T("Ahora está a %.0f°, por debajo de la altura mínima (%.0f°).", a0, minAltitude)
            : Strings.T("Le quedan %.1f h por encima de %.0f°: %.0f min de apilado dan buen resultado.", remaining / 60, minAltitude, minutes));
        return new CaptureAdvice(minutes, exp, gain, lp, remaining, a0, reasons);
    }
}
