using System.Globalization;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Model;
using Astrolabio.Core.Services;

namespace Astrolabio.Core.Reports;

/// <summary>Una noche de observación (de mediodía a mediodía).</summary>
public sealed record NightSession(DateTime Night, IReadOnlyList<ObservationRecord> Records)
{
    public DateTime Start => Records.Min(r => r.Start);
    public DateTime End => Records.Max(r => r.End);
    public int Frames => Records.Sum(r => r.Frames);
    public double IntegrationMinutes => Records.Sum(r => r.IntegrationMinutes);
    public List<string> Targets => Records.Select(r => r.Target).Distinct().ToList();
    public string? SiteName => Records.Select(r => r.SiteName).FirstOrDefault(s => s is not null);
    public double? Latitude => Records.Select(r => r.Latitude).FirstOrDefault(s => s is not null);
    public double? Longitude => Records.Select(r => r.Longitude).FirstOrDefault(s => s is not null);

    /// <summary>Agrupa el historial por noches, de la más reciente a la más antigua.</summary>
    public static List<NightSession> Group(IEnumerable<ObservationRecord> records) =>
        records.GroupBy(r => r.NightDate)
            .Select(g => new NightSession(g.Key, g.OrderBy(r => r.Start).ToList()))
            .OrderByDescending(n => n.Night).ToList();
}

public static class ReportFormat
{
    public static string Duration(double minutes)
    {
        var m = (int)Math.Round(minutes);
        return m >= 60 ? Strings.T("%d h %02d min", m / 60, m % 60) : Strings.T("%d min", m);
    }
    public static string Date(DateTime d) => d.ToString("D", Strings.Culture);
    public static string Time(DateTime utc) => utc.ToLocalTime().ToString("t", Strings.Culture);
    public static string Number(double x, int digits = 0) => x.ToString("F" + digits, Strings.Culture);
    public static string YesNo(bool b) => b ? Strings.T("Sí") : Strings.T("No");
}

public sealed record ReportRow(string Label, string Value);
public sealed record ReportObject(string Title, string Subtitle, List<ReportRow> Rows, byte[]? Image);

/// <summary>Contenido de un informe, ya traducido; lo usan la vista y el PDF.</summary>
public sealed record ReportDocument(string Title, string Subtitle, List<ReportRow> Summary, List<ReportRow> Conditions,
    List<ReportObject> Objects, List<string> Events, List<ReportRow> Device, string Footer)
{
    public static ReportDocument Make(NightSession s, IReadOnlyList<WeatherHour>? weather = null,
        IReadOnlyDictionary<Guid, byte[]>? images = null, (string Name, double Lat, double Lon)? site = null, DateTime? generated = null)
    {
        var lat = s.Latitude ?? site?.Lat;
        var lon = s.Longitude ?? site?.Lon;
        var mid = s.Start + (s.End - s.Start) / 2;
        var summary = new List<ReportRow>
        {
            new(Strings.T("Fecha"), ReportFormat.Date(s.Night)),
            new(Strings.T("Horario"), $"{ReportFormat.Time(s.Start)} – {ReportFormat.Time(s.End)}"),
            new(Strings.T("Objetos"), string.Join(", ", s.Targets)),
            new(Strings.T("Integración total"), ReportFormat.Duration(s.IntegrationMinutes)),
            new(Strings.T("Fotogramas apilados"), s.Frames.ToString(CultureInfo.InvariantCulture)),
        };
        if ((s.SiteName ?? site?.Name) is string name) summary.Add(new(Strings.T("Lugar"), name));
        if (lat is double la && lon is double lo)
            summary.Add(new(Strings.T("Coordenadas del lugar"), string.Create(CultureInfo.InvariantCulture, $"{la:F4}°, {lo:F4}°")));

        var conditions = new List<ReportRow>();
        var w = s.Records.Select(r => r.Weather).FirstOrDefault(x => x is not null)
            ?? (weather is null ? null : WeatherService.Nearest(mid, weather) is { } h
                ? new WeatherSnapshot(h.CloudCover, h.Temperature, h.DewPoint, h.Humidity, h.Wind) : null);
        if (w is not null)
            conditions.AddRange([
                new(Strings.T("Nubes"), $"{ReportFormat.Number(w.CloudCover)} %"),
                new(Strings.T("Temperatura"), $"{ReportFormat.Number(w.Temperature, 1)} °C"),
                new(Strings.T("Punto de rocío"), $"{ReportFormat.Number(w.DewPoint, 1)} °C"),
                new(Strings.T("Humedad"), $"{ReportFormat.Number(w.Humidity)} %"),
                new(Strings.T("Viento"), $"{ReportFormat.Number(w.Wind)} km/h"),
            ]);
        else conditions.Add(new(Strings.T("Tiempo"), Strings.T("Sin datos")));
        conditions.Add(new(Strings.T("Fase lunar"), Astro.MoonPhase(mid).Name));
        conditions.Add(new(Strings.T("Iluminación de la Luna"), $"{ReportFormat.Number(Astro.Moon(mid).Illumination * 100)} %"));
        if (lat is double mla && lon is double mlo)
        {
            var alt = Ephemeris.MoonAltitude(mla, mlo)(mid);
            conditions.Add(new(Strings.T("Altura de la Luna"), alt < 0 ? Strings.T("Bajo el horizonte") : $"{ReportFormat.Number(alt)}°"));
        }

        var objects = s.Records.Select(r =>
        {
            var rows = new List<ReportRow>();
            var obj = Catalog.Find(r.Target);
            if (r.Coordinates is { } co) rows.Add(new(Strings.T("AR / Dec"), $"{Astro.FormatRA(co.Ra)}  {Astro.FormatDec(co.Dec)}"));
            rows.Add(new(Strings.T("Inicio / fin"), $"{ReportFormat.Time(r.Start)} – {ReportFormat.Time(r.End)}"));
            rows.Add(new(Strings.T("Exposición"), Strings.T("%@ s", ReportFormat.Number(r.ExposureMs / 1000.0, r.ExposureMs % 1000 == 0 ? 0 : 1))));
            if (r.Gain is int g) rows.Add(new(Strings.T("Ganancia"), g.ToString(CultureInfo.InvariantCulture)));
            if (r.LpFilter is bool lp) rows.Add(new(Strings.T("Filtro LP"), ReportFormat.YesNo(lp)));
            var frames = r.Frames.ToString(CultureInfo.InvariantCulture);
            if (r.Dropped is int d) frames += "  " + Strings.T("(%d descartados)", d);
            rows.Add(new(Strings.T("Fotogramas apilados"), frames));
            rows.Add(new(Strings.T("Integración"), ReportFormat.Duration(r.IntegrationMinutes)));
            if (r.DitherEnabled is bool en)
                rows.Add(new(Strings.T("Dither"), en ? Strings.T("Sí, %d px cada %d fotogramas", r.DitherPixels ?? 0, r.DitherInterval ?? 0) : Strings.T("No")));
            if (r.FocusPosition is int f) rows.Add(new(Strings.T("Posición del enfoque"), f.ToString(CultureInfo.InvariantCulture)));
            var a1 = r.AltitudeStart; var a2 = r.AltitudeEnd;
            if ((a1 is null || a2 is null) && r.Coordinates is { } c2 && lat is double la2 && lon is double lo2)
            {
                double Alt(DateTime t) { var p = Astro.PrecessFromJ2000(c2.Ra, c2.Dec, t); return Astro.AltAz(p.Ra, p.Dec, t, la2, lo2).Alt; }
                a1 ??= Alt(r.Start); a2 ??= Alt(r.End);
            }
            if (a1 is double x1 && a2 is double x2) rows.Add(new(Strings.T("Altura inicio / fin"), $"{ReportFormat.Number(x1)}° / {ReportFormat.Number(x2)}°"));
            if (r.Imported == true) rows.Add(new(Strings.T("Origen"), Strings.T("Importado del álbum del Seestar")));
            var subtitle = string.Join(" · ", new[] { obj?.Kind.Label(), obj is null || obj.LocalizedName.Length == 0 ? null : obj.LocalizedName }.Where(x => x is not null));
            return new ReportObject(r.Target, subtitle, rows, images is not null && images.TryGetValue(r.Id, out var img) ? img : null);
        }).ToList();

        var events = s.Records.SelectMany(r => r.Events ?? []).ToList();

        var device = new List<ReportRow>();
        if (s.Records.Select(r => r.Device).FirstOrDefault(x => x is not null) is string dev) device.Add(new(Strings.T("Telescopio"), dev));
        if (s.Records.Select(r => r.Firmware).FirstOrDefault(x => x is not null) is string fw) device.Add(new(Strings.T("Firmware"), fw));
        var b1 = s.Records.Select(r => r.BatteryStart).FirstOrDefault(x => x is not null);
        var b2 = s.Records.Select(r => r.BatteryEnd).LastOrDefault(x => x is not null);
        if (b1 is int bb1 && b2 is int bb2) device.Add(new(Strings.T("Batería inicio / fin"), $"{bb1} % / {bb2} %"));
        if (s.Records.Select(r => r.Temperature).FirstOrDefault(x => x is not null) is double t)
            device.Add(new(Strings.T("Temperatura del telescopio"), $"{ReportFormat.Number(t, 1)} °C"));

        var footer = Strings.T("Generado con %@ %@ el %@", AppVersion.Name, AppVersion.Version, (generated ?? DateTime.Now).ToString("g", Strings.Culture));
        return new ReportDocument(Strings.T("Informe de sesión"), ReportFormat.Date(s.Night), summary, conditions, objects, events, device, footer);
    }
}

/// <summary>Nombre y versión de la aplicación (de los metadatos del ensamblado).</summary>
public static class AppVersion
{
    public const string Name = "Astrolabio";
    public static string Version
    {
        get
        {
            var v = typeof(AppVersion).Assembly.GetName().Version;
            return v is null ? "1.0.0" : $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }
}
