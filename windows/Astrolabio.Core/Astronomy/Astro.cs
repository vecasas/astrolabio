using System.Globalization;

namespace Astrolabio.Core.Astronomy;

/// <summary>
/// Cálculos astronómicos de baja precisión (suficientes para planificar y apuntar: el Seestar
/// corrige el error final con resolución de placa). Port directo de Astro.swift. Las fechas son UTC.
/// </summary>
public static class Astro
{
    public const double Deg = Math.PI / 180, Rad = 180 / Math.PI;

    public static double JulianDay(DateTime utc) =>
        (utc.ToUniversalTime() - DateTime.UnixEpoch).TotalSeconds / 86400 + 2440587.5;

    public static double Norm360(double x) { var r = x % 360; return r < 0 ? r + 360 : r; }

    /// <summary>Tiempo sidéreo local en grados.</summary>
    public static double LocalSiderealTime(DateTime utc, double lon)
    {
        var jd = JulianDay(utc);
        var t = (jd - 2451545.0) / 36525;
        return Norm360(280.46061837 + 360.98564736629 * (jd - 2451545.0) + 0.000387933 * t * t + lon);
    }

    /// <summary>Altura y acimut (grados; acimut desde el norte hacia el este).</summary>
    public static (double Alt, double Az) AltAz(double raHours, double decDeg, DateTime utc, double lat, double lon)
    {
        var ha = (LocalSiderealTime(utc, lon) - raHours * 15) * Deg;
        double d = decDeg * Deg, p = lat * Deg;
        var alt = Math.Asin(Math.Clamp(Math.Sin(d) * Math.Sin(p) + Math.Cos(d) * Math.Cos(p) * Math.Cos(ha), -1, 1));
        var y = -Math.Sin(ha) * Math.Cos(d);
        var x = Math.Sin(d) * Math.Cos(p) - Math.Cos(d) * Math.Cos(ha) * Math.Sin(p);
        return (alt * Rad, Norm360(Math.Atan2(y, x) * Rad));
    }

    public static (double Ra, double Dec) PrecessFromJ2000(double raHours, double decDeg, DateTime utc)
    {
        var years = (JulianDay(utc) - 2451545.0) / 365.25;
        double a = raHours * 15 * Deg, d = decDeg * Deg;
        var dRaSec = (3.07496 + 1.33621 * Math.Sin(a) * Math.Tan(d)) * years;
        var dDecArcsec = 20.0431 * Math.Cos(a) * years;
        var ra = raHours + dRaSec / 3600;
        if (ra < 0) ra += 24;
        if (ra >= 24) ra -= 24;
        return (ra, decDeg + dDecArcsec / 3600);
    }

    public static double Separation(double ra1, double dec1, double ra2, double dec2)
    {
        double a1 = ra1 * 15 * Deg, a2 = ra2 * 15 * Deg, d1 = dec1 * Deg, d2 = dec2 * Deg;
        return Math.Acos(Math.Clamp(Math.Sin(d1) * Math.Sin(d2) + Math.Cos(d1) * Math.Cos(d2) * Math.Cos(a1 - a2), -1, 1)) * Rad;
    }

    public static double Obliquity(double jd) => 23.439291 - 0.0130042 * (jd - 2451545.0) / 36525;

    public static (double Ra, double Dec) EclipticToEquatorial(double lambda, double beta, double jd)
    {
        double e = Obliquity(jd) * Deg, l = lambda * Deg, b = beta * Deg;
        var ra = Math.Atan2(Math.Sin(l) * Math.Cos(e) - Math.Tan(b) * Math.Sin(e), Math.Cos(l));
        var dec = Math.Asin(Math.Sin(b) * Math.Cos(e) + Math.Cos(b) * Math.Sin(e) * Math.Sin(l));
        return (Norm360(ra * Rad) / 15, dec * Rad);
    }

    public static (double Ra, double Dec, double Lambda) Sun(DateTime utc)
    {
        var n = JulianDay(utc) - 2451545.0;
        var L = Norm360(280.460 + 0.9856474 * n);
        var g = Norm360(357.528 + 0.9856003 * n) * Deg;
        var lambda = L + 1.915 * Math.Sin(g) + 0.020 * Math.Sin(2 * g);
        var eq = EclipticToEquatorial(lambda, 0, JulianDay(utc));
        return (eq.Ra, eq.Dec, Norm360(lambda));
    }

    public static (double Ra, double Dec, double Illumination, double Lambda) Moon(DateTime utc)
    {
        var jd = JulianDay(utc);
        var t = (jd - 2451545.0) / 36525;
        static double S(double x) => Math.Sin(x * Deg);
        var lambda = 218.32 + 481267.881 * t + 6.29 * S(135.0 + 477198.87 * t) - 1.27 * S(259.3 - 413335.36 * t)
            + 0.66 * S(235.7 + 890534.22 * t) + 0.21 * S(269.9 + 954397.74 * t) - 0.19 * S(357.5 + 35999.05 * t) - 0.11 * S(186.5 + 966404.03 * t);
        var beta = 5.13 * S(93.3 + 483202.02 * t) + 0.28 * S(228.2 + 960400.89 * t) - 0.28 * S(318.3 + 6003.15 * t) - 0.17 * S(217.6 - 407332.21 * t);
        var eq = EclipticToEquatorial(Norm360(lambda), beta, jd);
        var elong = Math.Acos(Math.Cos((Norm360(lambda) - Sun(utc).Lambda) * Deg) * Math.Cos(beta * Deg));
        return (eq.Ra, eq.Dec, (1 - Math.Cos(elong)) / 2, Norm360(lambda));
    }

    public static (double Age, string Name) MoonPhase(DateTime utc)
    {
        var angle = Norm360(Moon(utc).Lambda - Sun(utc).Lambda);
        var name = angle switch
        {
            < 10 or >= 350 => "Luna nueva", < 80 => "Creciente", < 100 => "Cuarto creciente", < 170 => "Gibosa creciente",
            < 190 => "Luna llena", < 260 => "Gibosa menguante", < 280 => "Cuarto menguante", _ => "Menguante",
        };
        return (angle / 360 * 29.530588, Strings.T(name));
    }

    // ------------------------------------------------------------ Planetas

    private sealed record Elements((double, double) A, (double, double) E, (double, double) I, (double, double) L, (double, double) W, (double, double) Node);

    private static readonly Dictionary<string, Elements> PlanetElements = new()
    {
        ["Mercurio"] = new((0.38709927, 0.00000037), (0.20563593, 0.00001906), (7.00497902, -0.00594749), (252.25032350, 149472.67411175), (77.45779628, 0.16047689), (48.33076593, -0.12534081)),
        ["Venus"] = new((0.72333566, 0.00000390), (0.00677672, -0.00004107), (3.39467605, -0.00078890), (181.97909950, 58517.81538729), (131.60246718, 0.00268329), (76.67984255, -0.27769418)),
        ["Tierra"] = new((1.00000261, 0.00000562), (0.01671123, -0.00004392), (-0.00001531, -0.01294668), (100.46457166, 35999.37244981), (102.93768193, 0.32327364), (0, 0)),
        ["Marte"] = new((1.52371034, 0.00001847), (0.09339410, 0.00007882), (1.84969142, -0.00813131), (-4.55343205, 19140.30268499), (-23.94362959, 0.44441088), (49.55953891, -0.29257343)),
        ["Júpiter"] = new((5.20288700, -0.00011607), (0.04838624, -0.00013253), (1.30439695, -0.00183714), (34.39644051, 3034.74612775), (14.72847983, 0.21252668), (100.47390909, 0.20469106)),
        ["Saturno"] = new((9.53667594, -0.00125060), (0.05386179, -0.00050991), (2.48599187, 0.00193609), (49.95424423, 1222.49362201), (92.59887831, -0.41897216), (113.66242448, -0.28867794)),
        ["Urano"] = new((19.18916464, -0.00196176), (0.04725744, -0.00004397), (0.77263783, -0.00242939), (313.23810451, 428.48202785), (170.95427630, 0.40805281), (74.01692503, 0.04240589)),
        ["Neptuno"] = new((30.06992276, 0.00026291), (0.00859048, 0.00005105), (1.77004347, 0.00035372), (-55.12002969, 218.45945325), (44.96476227, -0.32241464), (131.78422574, -0.00508664)),
    };

    public static readonly string[] PlanetNames = ["Mercurio", "Venus", "Marte", "Júpiter", "Saturno", "Urano", "Neptuno"];

    private static (double X, double Y, double Z) Heliocentric(Elements el, double t)
    {
        double a = el.A.Item1 + el.A.Item2 * t, e = el.E.Item1 + el.E.Item2 * t, i = (el.I.Item1 + el.I.Item2 * t) * Deg;
        double L = el.L.Item1 + el.L.Item2 * t, w = el.W.Item1 + el.W.Item2 * t, node = (el.Node.Item1 + el.Node.Item2 * t) * Deg;
        var argPeri = (w - el.Node.Item1 - el.Node.Item2 * t) * Deg;
        var M = Norm360(L - w); if (M > 180) M -= 360;
        var Mr = M * Deg;
        var E = Mr + e * Math.Sin(Mr);
        for (var k = 0; k < 8; k++) E -= (E - e * Math.Sin(E) - Mr) / (1 - e * Math.Cos(E));
        double xp = a * (Math.Cos(E) - e), yp = a * Math.Sqrt(1 - e * e) * Math.Sin(E);
        double co = Math.Cos(argPeri), so = Math.Sin(argPeri), cn = Math.Cos(node), sn = Math.Sin(node), ci = Math.Cos(i), si = Math.Sin(i);
        var x = (co * cn - so * sn * ci) * xp + (-so * cn - co * sn * ci) * yp;
        var y = (co * sn + so * cn * ci) * xp + (-so * sn + co * cn * ci) * yp;
        var z = so * si * xp + co * si * yp;
        return (x, y, z);
    }

    public static (double Ra, double Dec, double Distance)? Planet(string name, DateTime utc)
    {
        if (!PlanetElements.TryGetValue(name, out var el)) return null;
        var jd = JulianDay(utc);
        var t = (jd - 2451545.0) / 36525;
        var p = Heliocentric(el, t); var e = Heliocentric(PlanetElements["Tierra"], t);
        double x = p.X - e.X, y = p.Y - e.Y, z = p.Z - e.Z;
        var dist = Math.Sqrt(x * x + y * y + z * z);
        var eq = EclipticToEquatorial(Norm360(Math.Atan2(y, x) * Rad), Math.Atan2(z, Math.Sqrt(x * x + y * y)) * Rad, jd);
        var now = PrecessFromJ2000(eq.Ra, eq.Dec, utc);
        return (now.Ra, now.Dec, dist);
    }

    // ------------------------------------------------------------ Noche

    public sealed record Night(DateTime? DuskStart, DateTime? DawnEnd, DateTime? Sunset, DateTime? Sunrise);

    public static double SunAltitude(DateTime utc, double lat, double lon)
    {
        var s = Sun(utc);
        return AltAz(s.Ra, s.Dec, utc, lat, lon).Alt;
    }

    /// <summary>La noche que empieza el día local de <paramref name="local"/> (de mediodía a mediodía).</summary>
    public static Night NightFor(DateTime local, double lat, double lon)
    {
        var noon = local.Date.AddHours(12);
        if (local.Hour < 12) noon = noon.AddDays(-1);
        var t = noon.ToUniversalTime();
        var prev = SunAltitude(t, lat, lon);
        DateTime? sunset = null, sunrise = null, dusk = null, dawn = null;
        for (var k = 1; k <= 720; k++)
        {
            var tm = t.AddMinutes(2 * k);
            var alt = SunAltitude(tm, lat, lon);
            bool Down(double h) => prev >= h && alt < h;
            bool Up(double h) => prev < h && alt >= h;
            if (Down(-0.833) && sunset is null) sunset = tm;
            if (Down(-18) && dusk is null) dusk = tm;
            if (Up(-18) && dawn is null && dusk is not null) dawn = tm;
            if (Up(-0.833) && sunrise is null && sunset is not null) sunrise = tm;
            prev = alt;
        }
        return new Night(dusk, dawn, sunset, sunrise);
    }

    // ------------------------------------------------------------ Formato

    public static string FormatRA(double hours)
    {
        var h = hours % 24; if (h < 0) h += 24;
        var s = (int)Math.Round(h * 3600);
        return $"{s / 3600:00}h {s / 60 % 60:00}m {s % 60:00}s";
    }

    public static string FormatDec(double deg)
    {
        var s = (int)Math.Round(Math.Abs(deg) * 3600);
        return $"{(deg < 0 ? "-" : "+")}{s / 3600:00}° {s / 60 % 60:00}′ {s % 60:00}″";
    }

    public static double? ParseSexagesimal(string text)
    {
        var t = text.Trim();
        if (t.Length == 0) return null;
        var neg = t.StartsWith('-');
        var cleaned = new string(t.Select(c => char.IsDigit(c) || c is '.' or ',' ? c : ' ').ToArray()).Replace(',', '.');
        var parts = cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => double.TryParse(p, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : (double?)null)
            .Where(v => v is not null).Select(v => v!.Value).ToArray();
        if (parts.Length == 0) return null;
        var r = parts[0];
        if (parts.Length > 1) r += parts[1] / 60;
        if (parts.Length > 2) r += parts[2] / 3600;
        return neg ? -r : r;
    }
}
