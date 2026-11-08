namespace Astrolabio.Core.Astronomy;

public enum MoonFeatureKind { Crater, Mare, Mountain, Valley, Landing }

/// <summary>Accidente lunar con posición selenográfica (nombres de la UAI, dominio público).</summary>
public sealed record MoonFeature(string Name, double Lat, double Lon, double SizeKm, MoonFeatureKind Kind)
{
    public static string KindName(MoonFeatureKind k) => k switch
    {
        MoonFeatureKind.Crater => Strings.T("Cráter"),
        MoonFeatureKind.Mare => Strings.T("Mar"),
        MoonFeatureKind.Mountain => Strings.T("Montes"),
        MoonFeatureKind.Valley => Strings.T("Valle o falla"),
        _ => Strings.T("Alunizaje"),
    };
}

/// <summary>Libración óptica (punto subterrestre L, B) y punto subsolar (L0, B0), en grados.</summary>
public sealed record MoonGeometry(double L, double B, double L0, double B0)
{
    public double Colongitude => Astro.Norm360(90 - L0);
}

public enum MoonLight { Terminator, Lit, Dark, Hidden }

/// <summary>Port de MoonFeatures.swift (Meeus, cap. 53).</summary>
public static class MoonFeatures
{
    public static readonly MoonFeature[] All =
    [
        new("Mare Imbrium", 32.8, -15.6, 1146, MoonFeatureKind.Mare),
        new("Mare Serenitatis", 28.0, 17.5, 707, MoonFeatureKind.Mare),
        new("Mare Tranquillitatis", 8.5, 31.4, 873, MoonFeatureKind.Mare),
        new("Mare Crisium", 17.0, 59.1, 556, MoonFeatureKind.Mare),
        new("Mare Fecunditatis", -7.8, 51.3, 909, MoonFeatureKind.Mare),
        new("Mare Nectaris", -15.2, 35.5, 339, MoonFeatureKind.Mare),
        new("Mare Nubium", -21.3, -16.6, 715, MoonFeatureKind.Mare),
        new("Mare Humorum", -24.4, -38.6, 389, MoonFeatureKind.Mare),
        new("Oceanus Procellarum", 18.4, -57.4, 2568, MoonFeatureKind.Mare),
        new("Mare Frigoris", 56.0, 1.4, 1446, MoonFeatureKind.Mare),
        new("Mare Vaporum", 13.3, 3.6, 245, MoonFeatureKind.Mare),
        new("Sinus Iridum", 44.1, -31.5, 236, MoonFeatureKind.Mare),
        new("Sinus Medii", 2.4, 1.7, 335, MoonFeatureKind.Mare),
        new("Tycho", -43.3, -11.4, 85, MoonFeatureKind.Crater),
        new("Copernicus", 9.6, -20.1, 96, MoonFeatureKind.Crater),
        new("Kepler", 8.1, -38.0, 31, MoonFeatureKind.Crater),
        new("Aristarchus", 23.7, -47.4, 40, MoonFeatureKind.Crater),
        new("Plato", 51.6, -9.4, 101, MoonFeatureKind.Crater),
        new("Clavius", -58.4, -14.4, 225, MoonFeatureKind.Crater),
        new("Ptolemaeus", -9.2, -1.8, 153, MoonFeatureKind.Crater),
        new("Alphonsus", -13.4, -3.2, 108, MoonFeatureKind.Crater),
        new("Arzachel", -18.2, -1.9, 97, MoonFeatureKind.Crater),
        new("Archimedes", 29.7, -4.0, 81, MoonFeatureKind.Crater),
        new("Aristoteles", 50.2, 17.4, 87, MoonFeatureKind.Crater),
        new("Eudoxus", 44.3, 16.3, 67, MoonFeatureKind.Crater),
        new("Theophilus", -11.4, 26.4, 99, MoonFeatureKind.Crater),
        new("Cyrillus", -13.2, 24.0, 98, MoonFeatureKind.Crater),
        new("Catharina", -18.1, 23.6, 99, MoonFeatureKind.Crater),
        new("Langrenus", -8.9, 61.1, 132, MoonFeatureKind.Crater),
        new("Petavius", -25.3, 60.4, 177, MoonFeatureKind.Crater),
        new("Gassendi", -17.5, -40.1, 101, MoonFeatureKind.Crater),
        new("Grimaldi", -5.2, -68.6, 173, MoonFeatureKind.Crater),
        new("Schickard", -44.3, -54.6, 206, MoonFeatureKind.Crater),
        new("Longomontanus", -49.6, -21.9, 145, MoonFeatureKind.Crater),
        new("Maginus", -50.5, -6.3, 194, MoonFeatureKind.Crater),
        new("Posidonius", 31.9, 29.9, 95, MoonFeatureKind.Crater),
        new("Atlas", 46.7, 44.4, 87, MoonFeatureKind.Crater),
        new("Hercules", 46.7, 39.1, 69, MoonFeatureKind.Crater),
        new("Endymion", 53.6, 57.0, 123, MoonFeatureKind.Crater),
        new("Cleomedes", 27.6, 55.5, 125, MoonFeatureKind.Crater),
        new("Proclus", 16.1, 46.8, 28, MoonFeatureKind.Crater),
        new("Stöfler", -41.1, 6.0, 126, MoonFeatureKind.Crater),
        new("Walther", -33.0, 0.7, 128, MoonFeatureKind.Crater),
        new("Purbach", -25.5, -1.9, 115, MoonFeatureKind.Crater),
        new("Regiomontanus", -28.4, -0.6, 126, MoonFeatureKind.Crater),
        new("Albategnius", -11.2, 4.0, 136, MoonFeatureKind.Crater),
        new("Hipparchus", -5.1, 5.2, 138, MoonFeatureKind.Crater),
        new("Manilius", 14.5, 9.1, 39, MoonFeatureKind.Crater),
        new("Menelaus", 16.3, 16.0, 26, MoonFeatureKind.Crater),
        new("Plinius", 15.4, 23.6, 41, MoonFeatureKind.Crater),
        new("Eratosthenes", 14.5, -11.3, 58, MoonFeatureKind.Crater),
        new("Bullialdus", -20.7, -22.2, 61, MoonFeatureKind.Crater),
        new("Mersenius", -21.5, -49.2, 84, MoonFeatureKind.Crater),
        new("Pitatus", -29.8, -13.5, 106, MoonFeatureKind.Crater),
        new("Wargentin", -49.6, -60.2, 84, MoonFeatureKind.Crater),
        new("Janssen", -44.9, 40.8, 190, MoonFeatureKind.Crater),
        new("Maurolycus", -41.8, 14.0, 114, MoonFeatureKind.Crater),
        new("Piccolomini", -29.7, 32.2, 88, MoonFeatureKind.Crater),
        new("Fracastorius", -21.5, 33.2, 124, MoonFeatureKind.Crater),
        new("Fra Mauro", -6.0, -17.0, 101, MoonFeatureKind.Crater),
        new("Hevelius", 2.2, -67.6, 115, MoonFeatureKind.Crater),
        new("Riccioli", -3.0, -74.6, 139, MoonFeatureKind.Crater),
        new("Pythagoras", 63.5, -63.0, 142, MoonFeatureKind.Crater),
        new("Montes Apenninus", 18.9, -3.7, 600, MoonFeatureKind.Mountain),
        new("Montes Alpes", 46.4, -0.8, 281, MoonFeatureKind.Mountain),
        new("Montes Caucasus", 38.4, 10.0, 445, MoonFeatureKind.Mountain),
        new("Mons Pico", 45.8, -8.9, 25, MoonFeatureKind.Mountain),
        new("Mons Piton", 40.6, -1.1, 25, MoonFeatureKind.Mountain),
        new("Vallis Alpes", 48.5, 3.2, 155, MoonFeatureKind.Valley),
        new("Rupes Recta", -22.1, -7.8, 110, MoonFeatureKind.Valley),
        new("Vallis Schröteri", 26.2, -50.8, 168, MoonFeatureKind.Valley),
        new("Apollo 11", 0.67, 23.47, 1, MoonFeatureKind.Landing),
        new("Apollo 15", 26.13, 3.63, 1, MoonFeatureKind.Landing),
        new("Apollo 17", 20.19, 30.77, 1, MoonFeatureKind.Landing)
    ];

    public static (double Lambda, double Beta) MoonEcliptic(DateTime utc)
    {
        var t = (Astro.JulianDay(utc) - 2451545.0) / 36525;
        static double S(double x) => Math.Sin(x * Astro.Deg);
        var lambda = 218.32 + 481267.881 * t
            + 6.29 * S(135.0 + 477198.87 * t) - 1.27 * S(259.3 - 413335.36 * t)
            + 0.66 * S(235.7 + 890534.22 * t) + 0.21 * S(269.9 + 954397.74 * t)
            - 0.19 * S(357.5 + 35999.05 * t) - 0.11 * S(186.5 + 966404.03 * t);
        var beta = 5.13 * S(93.3 + 483202.02 * t) + 0.28 * S(228.2 + 960400.89 * t)
            - 0.28 * S(318.3 + 6003.15 * t) - 0.17 * S(217.6 - 407332.21 * t);
        return (Astro.Norm360(lambda), beta);
    }

    private static (double L, double B) Libration(double lambda, double beta, double t)
    {
        double d = Astro.Deg, inc = 1.54242 * d;
        var node = (125.0445479 - 1934.1362891 * t) * d;
        var f = (93.2720950 + 483202.0175233 * t) * d;
        double w = lambda * d - node, be = beta * d;
        var a = Math.Atan2(Math.Sin(w) * Math.Cos(be) * Math.Cos(inc) - Math.Sin(be) * Math.Sin(inc), Math.Cos(w) * Math.Cos(be));
        var l = Astro.Norm360((a - f) / d); if (l > 180) l -= 360;
        var b = Math.Asin(-Math.Sin(w) * Math.Cos(be) * Math.Sin(inc) - Math.Sin(be) * Math.Cos(inc)) / d;
        return (l, b);
    }

    public static MoonGeometry Geometry(DateTime utc)
    {
        var t = (Astro.JulianDay(utc) - 2451545.0) / 36525;
        var m = MoonEcliptic(utc);
        var earth = Libration(m.Lambda, m.Beta, t);
        var sunL = Astro.Sun(utc).Lambda;
        var ratio = Ephemeris.MoonDistanceKm(utc) / 149_597_870.7;
        var lh = sunL + 180 + ratio * Astro.Rad * Math.Cos(m.Beta * Astro.Deg) * Math.Sin((sunL - m.Lambda) * Astro.Deg);
        var sun = Libration(Astro.Norm360(lh), ratio * m.Beta, t);
        return new MoonGeometry(earth.L, earth.B, sun.L, sun.B);
    }

    public static (double X, double Y, double Z) Vector(double lat, double lon)
    {
        double p = lat * Astro.Deg, l = lon * Astro.Deg;
        return (Math.Cos(p) * Math.Sin(l), Math.Sin(p), Math.Cos(p) * Math.Cos(l));
    }

    static double Dot((double X, double Y, double Z) a, (double X, double Y, double Z) b) => a.X * b.X + a.Y * b.Y + a.Z * b.Z;

    /// <summary>Ejes de la vista (x derecha, y arriba, z hacia el observador) en el sistema lunar, norte arriba.</summary>
    public static ((double X, double Y, double Z) Ex, (double X, double Y, double Z) Ey, (double X, double Y, double Z) Ez) ViewBasis(MoonGeometry g)
    {
        double l = g.L * Astro.Deg, b = g.B * Astro.Deg;
        return ((Math.Cos(l), 0, -Math.Sin(l)), (-Math.Sin(b) * Math.Sin(l), Math.Cos(b), -Math.Sin(b) * Math.Cos(l)),
                (Math.Cos(b) * Math.Sin(l), Math.Sin(b), Math.Cos(b) * Math.Cos(l)));
    }

    public static (double X, double Y, bool Visible) Project(MoonFeature f, MoonGeometry g)
    {
        var v = Vector(f.Lat, f.Lon); var e = ViewBasis(g);
        return (Dot(v, e.Ex), Dot(v, e.Ey), Dot(v, e.Ez) > 0.05);
    }

    public static double SunAltitude(MoonFeature f, MoonGeometry g) =>
        Math.Asin(Math.Clamp(Dot(Vector(g.B0, g.L0), Vector(f.Lat, f.Lon)), -1, 1)) * Astro.Rad;

    public static (double X, double Y, double Z) SunInView(MoonGeometry g)
    {
        var s = Vector(g.B0, g.L0); var e = ViewBasis(g);
        return (Dot(s, e.Ex), Dot(s, e.Ey), Dot(s, e.Ez));
    }

    public static MoonLight Light(MoonFeature f, MoonGeometry g)
    {
        if (!Project(f, g).Visible) return MoonLight.Hidden;
        var h = SunAltitude(f, g);
        var limit = f.Kind == MoonFeatureKind.Mare ? 25.0 : 12.0;
        if (h < 0) return MoonLight.Dark;
        return h <= limit ? MoonLight.Terminator : MoonLight.Lit;
    }

    public static List<MoonFeature> BestNow(MoonGeometry g, int limit = 10) =>
        All.Where(f => f.Kind != MoonFeatureKind.Mare && Light(f, g) == MoonLight.Terminator)
           .OrderByDescending(f => f.SizeKm).Take(limit).ToList();

    /// <summary>Rótulos por defecto: mares grandes iluminados y lo mejor junto al terminador, sin solaparse.</summary>
    public static List<MoonFeature> DefaultLabels(MoonGeometry g)
    {
        var maria = All.Where(f => f.Kind == MoonFeatureKind.Mare && f.SizeKm > 500 && Light(f, g) is MoonLight.Lit or MoonLight.Terminator);
        var placed = new List<(double X, double Y)>();
        var res = new List<MoonFeature>();
        foreach (var f in maria.Concat(BestNow(g, 12)))
        {
            var p = Project(f, g);
            if (placed.Any(q => Math.Abs(q.X - p.X) < 0.22 && Math.Abs(q.Y - p.Y) < 0.07)) continue;
            placed.Add((p.X, p.Y)); res.Add(f);
        }
        return res;
    }

    public static string LightName(MoonLight l) => l switch
    {
        MoonLight.Terminator => Strings.T("Junto al terminador"),
        MoonLight.Lit => Strings.T("Iluminado"),
        MoonLight.Dark => Strings.T("De noche"),
        _ => Strings.T("Cara oculta"),
    };
}
