using System.Globalization;

namespace Astrolabio.Core.Astronomy;

/// <summary>Órbita de un cometa (elementos del Minor Planet Center, eclíptica J2000). Igual que Comets.swift.</summary>
public sealed record CometOrbit(string Name, double PerihelionJD, double Q, double E, double ArgPeri, double Node, double Incl, double H, double G);

public sealed record CometPosition(double RaHours, double DecDeg, double R, double Delta, double Magnitude);

public static class Comets
{
    public const double K = 0.01720209895;
    public const int MaxBytes = 2 * 1024 * 1024;

    public static List<CometOrbit> Parse(string text)
    {
        var o = new List<CometOrbit>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length < 103) continue;
            string F(int a, int b) => line[Math.Min(a, line.Length)..Math.Min(b, line.Length)].Trim();
            double? N(int a, int b) => double.TryParse(F(a, b), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;
            if (!int.TryParse(F(14, 18), out var year) || !int.TryParse(F(19, 21), out var month) || month is < 1 or > 12) continue;
            if (N(22, 29) is not double day || N(30, 39) is not double q || N(41, 49) is not double e || N(51, 59) is not double w ||
                N(61, 69) is not double node || N(71, 79) is not double i || q <= 0 || e < 0 || e >= 10) continue;
            var name = F(102, 158);
            if (name.Length == 0) continue;
            o.Add(new CometOrbit(name, JulianDay(year, month, day), q, e, w, node, i, N(91, 95) ?? 15, N(96, 100) ?? 4));
        }
        return o;
    }

    public static double JulianDay(int year, int month, double day)
    {
        double y = year, m = month;
        if (m <= 2) { y -= 1; m += 12; }
        var a = Math.Floor(y / 100); var b = 2 - a + Math.Floor(a / 4);
        return Math.Floor(365.25 * (y + 4716)) + Math.Floor(30.6001 * (m + 1)) + day + b - 1524.5;
    }

    public static (double X, double Y, double Z, double R) Heliocentric(CometOrbit o, double jd)
    {
        var dt = jd - o.PerihelionJD;
        double xv, yv;
        if (Math.Abs(o.E - 1) < 1e-6)
        {
            var w = 3 * K * dt / (Math.Sqrt(2) * Math.Pow(o.Q, 1.5));
            var yb = Math.Cbrt(w / 2 + Math.Sqrt(w * w / 4 + 1));
            var s = yb - 1 / yb;
            xv = o.Q * (1 - s * s); yv = 2 * o.Q * s;
        }
        else if (o.E < 1)
        {
            var a = o.Q / (1 - o.E);
            var mm = Math.IEEERemainder(K * dt / Math.Pow(a, 1.5), 2 * Math.PI);
            var ea = mm + 0.85 * o.E * (Math.Sin(mm) >= 0 ? 1 : -1);
            for (var it = 0; it < 100; it++)
            {
                var d = (ea - o.E * Math.Sin(ea) - mm) / (1 - o.E * Math.Cos(ea));
                ea -= d;
                if (Math.Abs(d) < 1e-12) break;
            }
            xv = a * (Math.Cos(ea) - o.E); yv = a * Math.Sqrt(1 - o.E * o.E) * Math.Sin(ea);
        }
        else
        {
            var a = o.Q / (o.E - 1);
            var m = K * dt / Math.Pow(a, 1.5);
            var h = Math.Asinh(m / o.E);
            for (var it = 0; it < 100; it++)
            {
                var d = (o.E * Math.Sinh(h) - h - m) / (o.E * Math.Cosh(h) - 1);
                h -= d;
                if (Math.Abs(d) < 1e-12) break;
            }
            xv = a * (o.E - Math.Cosh(h)); yv = a * Math.Sqrt(o.E * o.E - 1) * Math.Sinh(h);
        }
        var r = Math.Sqrt(xv * xv + yv * yv);
        var v = Math.Atan2(yv, xv);
        const double deg = Math.PI / 180;
        double nd = o.Node * deg, u = o.ArgPeri * deg + v, inc = o.Incl * deg;
        return (r * (Math.Cos(nd) * Math.Cos(u) - Math.Sin(nd) * Math.Sin(u) * Math.Cos(inc)),
                r * (Math.Sin(nd) * Math.Cos(u) + Math.Cos(nd) * Math.Sin(u) * Math.Cos(inc)),
                r * Math.Sin(u) * Math.Sin(inc), r);
    }

    public static (double X, double Y, double Z) Earth(double jd)
    {
        var n = jd - 2451545.0;
        var g = (357.528 + 0.9856003 * n) * Math.PI / 180;
        var lambda = (280.460 + 0.9856474 * n + 1.915 * Math.Sin(g) + 0.020 * Math.Sin(2 * g) - 1.3970 * n / 36525) * Math.PI / 180;
        var r = 1.00014 - 0.01671 * Math.Cos(g) - 0.00014 * Math.Cos(2 * g);
        return (-r * Math.Cos(lambda), -r * Math.Sin(lambda), 0);
    }

    public static CometPosition Position(CometOrbit o, DateTime utc)
    {
        var jd = Astro.JulianDay(utc) + 69.2 / 86400;
        var e = Earth(jd);
        var c = Heliocentric(o, jd);
        double dx = c.X - e.X, dy = c.Y - e.Y, dz = c.Z - e.Z;
        var delta = Math.Sqrt(dx * dx + dy * dy + dz * dz);
        c = Heliocentric(o, jd - delta * 0.0057755183);
        dx = c.X - e.X; dy = c.Y - e.Y; dz = c.Z - e.Z;
        delta = Math.Sqrt(dx * dx + dy * dy + dz * dz);
        var eps = 23.4392911 * Math.PI / 180;
        double xq = dx, yq = dy * Math.Cos(eps) - dz * Math.Sin(eps), zq = dy * Math.Sin(eps) + dz * Math.Cos(eps);
        var ra = Math.Atan2(yq, xq) * 180 / Math.PI / 15;
        if (ra < 0) ra += 24;
        var dec = Math.Asin(zq / delta) * 180 / Math.PI;
        return new CometPosition(ra, dec, c.R, delta, o.H + 5 * Math.Log10(delta) + 2.5 * o.G * Math.Log10(c.R));
    }

    public sealed record Forecast(CometOrbit Orbit, CometPosition Position, double MaxAltitude, DateTime? Best, double UsableMinutes);

    public static List<Forecast> Visible(IEnumerable<CometOrbit> orbits, Astro.Night night, double lat, double lon, double minAltitude, double maxMagnitude = 12, Model.Horizon? horizon = null)
    {
        var hz = horizon ?? Model.Horizon.Flat;
        if (night.DuskStart is not DateTime s || night.DawnEnd is not DateTime e || e <= s) return [];
        var mid = s + (e - s) / 2;
        var times = new List<DateTime>();
        for (var t = s; t <= e; t = t.AddMinutes(15)) times.Add(t);
        var o = new List<Forecast>();
        foreach (var orb in orbits)
        {
            var p = Position(orb, mid);
            if (!(p.Magnitude <= maxMagnitude)) continue;
            var now = Astro.PrecessFromJ2000(p.RaHours, p.DecDeg, mid);
            double maxAlt = -90, usable = 0; DateTime? best = null;
            foreach (var t in times)
            {
                var aa = Astro.AltAz(now.Ra, now.Dec, t, lat, lon);
                if (aa.Alt > maxAlt) { maxAlt = aa.Alt; best = t; }
                if (hz.IsVisible(aa.Alt, aa.Az, minAltitude)) usable += 15;
            }
            if (usable > 0) o.Add(new Forecast(orb, p, maxAlt, best, usable));
        }
        return o.OrderBy(f => f.Position.Magnitude).ToList();
    }
}
