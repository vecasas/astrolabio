using Astrolabio.Core.Astronomy;

namespace Astrolabio.Core.Model;

public enum PickStyle { Best, Easy, Challenge, Surprise }

public static class PickStyleExt
{
    public static string Key(this PickStyle s) => s switch
    {
        PickStyle.Best => "Lo mejor ahora", PickStyle.Easy => "Fácil y brillante", PickStyle.Challenge => "Un reto", _ => "Sorpréndeme",
    };
}

public sealed record Suggestion(TargetForecast Forecast, double AltitudeNow, double RemainingMinutes, DateTime Start, List<string> Reasons);

/// <summary>«Elige por mí» y el plan corto para el resto de la noche (port de Tonight.swift).</summary>
public static class PickForMe
{
    public static List<Suggestion> Suggestions(IReadOnlyList<TargetForecast> forecasts, Astro.Night? night, PickStyle style,
        double lat, double lon, double minAltitude, DateTime? nowUtc = null, Horizon? horizon = null)
    {
        var limit = new SkyLimit(minAltitude, horizon ?? Horizon.Flat);
        var start = nowUtc ?? DateTime.UtcNow;
        if (night?.DuskStart is DateTime dusk && start < dusk) start = dusk;
        var end = night?.DawnEnd ?? start.AddHours(6);
        if (end <= start) return [];
        var res = new List<Suggestion>();
        foreach (var f in forecasts.Where(f => f.Score > 0))
        {
            var alt = Ephemeris.FixedAltitude(f.Object.RaHours, f.Object.DecDeg, lat, lon);
            var clear = limit.ClearFixed(f.Object.RaHours, f.Object.DecDeg, lat, lon);
            var a0 = alt(start);
            if (!clear(start)) continue;
            double remaining = 0, peak = a0; var peakTime = start;
            for (var t = start; t < end; t = t.AddMinutes(10))
            {
                var a = alt(t);
                if (!clear(t)) break;
                if (a > peak) { peak = a; peakTime = t; }
                remaining += 10;
            }
            if (remaining < 40) continue;
            var reasons = new List<string>();
            if (peakTime > start.AddMinutes(10))
                reasons.Add(Strings.T("Está a %.0f° y sube hasta %.0f° hacia las %@.", a0, peak, peakTime.ToLocalTime().ToString("t", Strings.Culture)));
            else if (alt(start.AddMinutes(30)) < a0 - 1)
                reasons.Add(Strings.T("Está a %.0f° y empieza a bajar: mejor ahora que más tarde.", a0));
            else reasons.Add(Strings.T("Está a %.0f° de altura, en su mejor momento.", a0));
            reasons.Add(Strings.T("Quedan %.1f h por encima de %.0f°.", remaining / 60, minAltitude));
            reasons.Add(Strings.T("La Luna está a %.0f°%@.", f.MoonSeparation,
                f.MoonSeparation > 60 ? Strings.T(", lejos") : f.MoonSeparation < 30 ? Strings.T(", demasiado cerca") : ""));
            reasons.Add(f.Fit.Kind switch
            {
                "good" => Strings.T("Cabe entero en el campo del Seestar."),
                "small" => Strings.T("Es pequeño: después conviene recortar la imagen."),
                _ => Strings.T("Es grande: queda mejor como mosaico %@×%@.", f.Fit.Columns, f.Fit.Rows),
            });
            if (f.Object.Kind.WantsLP()) reasons.Add(Strings.T("Es una nebulosa de emisión: el filtro antipolución ayuda."));
            if (f.MeanCloud is double c) reasons.Add(Strings.T("Nubes previstas: %.0f %%.", c));
            res.Add(new Suggestion(f, a0, remaining, start, reasons));
        }
        return style switch
        {
            PickStyle.Best => res.OrderByDescending(s => s.Forecast.Score + Math.Min(s.RemainingMinutes, 240) / 24).ToList(),
            PickStyle.Easy => res.Where(s => s.Forecast.Object.Magnitude <= 8 && s.Forecast.Fit.Kind != "small")
                                 .OrderBy(s => s.Forecast.Object.Magnitude - s.Forecast.Score / 20).ToList(),
            PickStyle.Challenge => res.Where(s => s.Forecast.Object.Magnitude > 9 || s.Forecast.Object.Kind == ObjectKind.Snr)
                                      .OrderByDescending(s => s.Forecast.Score).ToList(),
            _ => res.OrderByDescending(s => s.Forecast.Score).Take(15).OrderBy(_ => Random.Shared.Next()).ToList(),
        };
    }

    public static List<PlanItem> ShortPlan(IReadOnlyList<TargetForecast> forecasts, Astro.Night? night, double lat, double lon,
        double minAltitude, int maxTargets = 3, DateTime? nowUtc = null, Horizon? horizon = null)
    {
        var limit = new SkyLimit(minAltitude, horizon ?? Horizon.Flat);
        var start = nowUtc ?? DateTime.UtcNow;
        if (night?.DuskStart is DateTime dusk && start < dusk) start = dusk;
        if (night?.DawnEnd is not DateTime end || end <= start.AddMinutes(30)) return [];
        var total = (end - start).TotalSeconds;
        var n = Math.Max(1, Math.Min(maxTargets, (int)(total / 3600 / 1.2)));
        var slot = total / n;
        var used = new HashSet<string>();
        var items = new List<PlanItem>();
        for (var i = 0; i < n; i++)
        {
            var s = start.AddSeconds(i * slot); var e = s.AddSeconds(slot);
            var best = forecasts.Where(f => !used.Contains(f.Object.Id) && f.Score > 0)
                .Select(f =>
                {
                    var alt = Ephemeris.FixedAltitude(f.Object.RaHours, f.Object.DecDeg, lat, lon);
                    double a1 = alt(s), a2 = alt(s.AddSeconds(slot / 2)), a3 = alt(e);
                    var clear = limit.ClearFixed(f.Object.RaHours, f.Object.DecDeg, lat, lon);
                    return (f, ok: clear(s) && clear(s.AddSeconds(slot / 2)) && clear(e), score: f.Score + (a1 + a2 + a3) / 9);
                })
                .Where(x => x.ok).OrderByDescending(x => x.score).FirstOrDefault();
            if (best.f is null) continue;
            used.Add(best.f.Object.Id);
            items.Add(new PlanItem
            {
                Name = best.f.Object.Id, RaHours = best.f.Object.RaHours, DecDeg = best.f.Object.DecDeg,
                Minutes = Math.Max(30, Math.Round(slot / 60 * 0.85 / 10) * 10), LpFilter = best.f.Object.Kind.WantsLP(),
                NotBefore = i == 0 ? null : s,
            });
        }
        return items;
    }

    /// <summary>Nota de 0 a 100 para la noche: duración de la oscuridad, nubes y Luna.</summary>
    public static (double Score, double? Cloud, double MoonFactor)? NightQuality(Astro.Night? n, IReadOnlyList<Services.WeatherHour> weather)
    {
        if (n?.DuskStart is not DateTime start || n.DawnEnd is not DateTime end || end <= start) return null;
        var hours = (end - start).TotalHours;
        double sum = 0, cnt = 0;
        for (var t = start; t <= end; t = t.AddHours(1)) if (Services.WeatherService.CloudCover(t, weather) is double c) { sum += c; cnt++; }
        double? cloud = cnt > 0 ? sum / cnt : null;
        var moon = Astro.Moon(start + (end - start) / 2).Illumination;
        var score = Math.Min(1, hours / 8) * 100;
        if (cloud is double cl) score *= 1 - cl / 100 * 0.9;
        score *= 1 - moon * 0.45;
        return (score, cloud, moon);
    }
}
