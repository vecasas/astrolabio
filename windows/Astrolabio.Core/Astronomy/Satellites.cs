using System.Globalization;
using Astrolabio.Core.Model;
using Astrolabio.Core.Services;

namespace Astrolabio.Core.Astronomy;

/// <summary>Elementos orbitales en formato TLE. Port de SGP4.swift.</summary>
public sealed record Tle(string Name, string Line1, string Line2, double EpochJD, double Bstar,
                         double Incl, double Node, double Ecc, double Argp, double Mo, double NoKozai)
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public static Tle? Parse(string name, string l1, string l2)
    {
        if (l1.Length < 69 || l2.Length < 69 || l1[0] != '1' || l2[0] != '2' || !ChecksumOk(l1) || !ChecksumOk(l2)) return null;
        static string F(string s, int a, int b) => s[a..b].Trim();
        static double? D(string s, int a, int b) => double.TryParse(F(s, a, b), NumberStyles.Float, Inv, out var v) ? v : null;
        static double? Exp(string t)
        {
            t = t.Trim();
            if (t.Length < 2) return 0;
            var mant = t[..^2]; var e = t[^2..];
            if (!mant.StartsWith('-') && !mant.StartsWith('+')) mant = "+" + mant;
            var sign = mant[0] == '-' ? -1.0 : 1.0;
            mant = mant[1..];
            if (!double.TryParse("0." + mant, NumberStyles.Float, Inv, out var m) || !double.TryParse(e, NumberStyles.Float, Inv, out var ex)) return null;
            return sign * m * Math.Pow(10, ex);
        }
        if (!int.TryParse(F(l1, 18, 20), out var yy) || D(l1, 20, 32) is not double doy || Exp(F(l1, 53, 61)) is not double bs
            || D(l2, 8, 16) is not double inc || D(l2, 17, 25) is not double raan
            || !double.TryParse("0." + F(l2, 26, 33), NumberStyles.Float, Inv, out var ecc)
            || D(l2, 34, 42) is not double ap || D(l2, 43, 51) is not double ma || D(l2, 52, 63) is not double nrev || nrev <= 0) return null;
        var year = yy < 57 ? 2000 + yy : 1900 + yy;
        var jan1 = Comets.JulianDay(year, 1, 1);
        var r = Math.PI / 180;
        return new Tle(name.Trim(), l1, l2, jan1 + doy - 1, bs, inc * r, raan * r, ecc, ap * r, ma * r, nrev * 2 * Math.PI / 1440);
    }

    public static bool ChecksumOk(string c)
    {
        var sum = 0;
        for (var i = 0; i < 68; i++) { if (char.IsDigit(c[i])) sum += c[i] - '0'; else if (c[i] == '-') sum += 1; }
        return char.IsDigit(c[68]) && c[68] - '0' == sum % 10;
    }

    public static List<Tle> ParseList(string text, int max = 2000)
    {
        var lines = text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
        var res = new List<Tle>();
        var i = 0;
        while (i + 2 < lines.Count && res.Count < max)
        {
            if (!lines[i].StartsWith("1 ") && lines[i + 1].StartsWith("1 ") && lines[i + 2].StartsWith("2 ")
                && Parse(lines[i], lines[i + 1], lines[i + 2]) is Tle t) { res.Add(t); i += 3; }
            else i++;
        }
        return res;
    }
}

/// <summary>SGP4 cercano a la Tierra (periodo &lt; 225 min), WGS-72, según Vallado et al. (2006). Salida TEME en km y km/s.</summary>
public sealed class Sgp4
{
    const double Re = 6378.135, Mu = 398600.8;
    static readonly double Xke = 60.0 / Math.Sqrt(Re * Re * Re / Mu);
    const double J2 = 0.001082616, J3 = -0.00000253881, J4 = -0.00000165597, J3oJ2 = J3 / J2;

    public Tle Tle { get; }
    readonly bool isimp;
    readonly double aycof, con41, cc1, cc4, cc5, d2, d3, d4, delmo, eta, argpdot, omgcof, sinmao, t2cof, t3cof, t4cof, t5cof,
        x1mth2, x7thm1, mdot, nodedot, xlcof, xmcof, nodecf, noUnkozai;

    private Sgp4(Tle tle)
    {
        Tle = tle;
        double e = tle.Ecc, i = tle.Incl;
        double cosio = Math.Cos(i), cosio2 = cosio * cosio, eccsq = e * e, omeosq = 1 - eccsq, rteosq = Math.Sqrt(omeosq);
        var ak = Math.Pow(Xke / tle.NoKozai, 2.0 / 3);
        var d1 = 0.75 * J2 * (3 * cosio2 - 1) / (rteosq * omeosq);
        var del = d1 / (ak * ak);
        var adel = ak * (1 - del * del - del * (1.0 / 3 + 134 * del * del / 81));
        del = d1 / (adel * adel);
        noUnkozai = tle.NoKozai / (1 + del);
        var ao = Math.Pow(Xke / noUnkozai, 2.0 / 3);
        double sinio = Math.Sin(i), po = ao * omeosq, con42 = 1 - 5 * cosio2;
        con41 = -con42 - cosio2 - cosio2;
        double posq = po * po, rp = ao * (1 - e);
        isimp = rp < 220 / Re + 1;
        var sfour = 78 / Re + 1;
        var qzms24 = Math.Pow((120 - 78) / Re, 4);
        var perige = (rp - 1) * Re;
        if (perige < 156)
        {
            sfour = perige - 78;
            if (perige < 98) sfour = 20;
            qzms24 = Math.Pow((120 - sfour) / Re, 4);
            sfour = sfour / Re + 1;
        }
        double pinvsq = 1 / posq, tsi = 1 / (ao - sfour);
        eta = ao * e * tsi;
        double etasq = eta * eta, eeta = e * eta, psisq = Math.Abs(1 - etasq);
        double coef = qzms24 * Math.Pow(tsi, 4), coef1 = coef / Math.Pow(psisq, 3.5);
        var cc2 = coef1 * noUnkozai * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq))
                  + 0.375 * J2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)));
        cc1 = tle.Bstar * cc2;
        var cc3 = e > 1e-4 ? -2 * coef * tsi * J3oJ2 * noUnkozai * sinio / e : 0;
        x1mth2 = 1 - cosio2;
        cc4 = 2 * noUnkozai * coef1 * ao * omeosq * (eta * (2 + 0.5 * etasq) + e * (0.5 + 2 * etasq)
              - J2 * tsi / (ao * psisq) * (-3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta))
              + 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * Math.Cos(2 * tle.Argp)));
        cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq);
        var cosio4 = cosio2 * cosio2;
        double temp1 = 1.5 * J2 * pinvsq * noUnkozai, temp2 = 0.5 * temp1 * J2 * pinvsq, temp3 = -0.46875 * J4 * pinvsq * pinvsq * noUnkozai;
        mdot = noUnkozai + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4);
        argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4) + temp3 * (3 - 36 * cosio2 + 49 * cosio4);
        var xhdot1 = -temp1 * cosio;
        nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio;
        omgcof = tle.Bstar * cc3 * Math.Cos(tle.Argp);
        xmcof = e > 1e-4 ? -2.0 / 3 * coef * tle.Bstar / eeta : 0;
        nodecf = 3.5 * omeosq * xhdot1 * cc1;
        t2cof = 1.5 * cc1;
        xlcof = Math.Abs(cosio + 1) > 1.5e-12 ? -0.25 * J3oJ2 * sinio * (3 + 5 * cosio) / (1 + cosio)
                                               : -0.25 * J3oJ2 * sinio * (3 + 5 * cosio) / 1.5e-12;
        aycof = -0.5 * J3oJ2 * sinio;
        delmo = Math.Pow(1 + eta * Math.Cos(tle.Mo), 3);
        sinmao = Math.Sin(tle.Mo);
        x7thm1 = 7 * cosio2 - 1;
        if (!isimp)
        {
            var cc1sq = cc1 * cc1;
            d2 = 4 * ao * tsi * cc1sq;
            var temp = d2 * tsi * cc1 / 3;
            d3 = (17 * ao + sfour) * temp;
            d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1;
            t3cof = d2 + 2 * cc1sq;
            t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq));
            t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq));
        }
    }

    /// <summary>null si la órbita es de espacio profundo (este modelo no la cubre).</summary>
    public static Sgp4? Create(Tle tle)
    {
        var s = new Sgp4(tle);
        return 2 * Math.PI / s.noUnkozai < 225 ? s : null;
    }

    public ((double X, double Y, double Z) R, (double X, double Y, double Z) V)? Propagate(double t)
    {
        const double twopi = 2 * Math.PI;
        double xmdf = Tle.Mo + mdot * t, argpdf = Tle.Argp + argpdot * t, nodedf = Tle.Node + nodedot * t;
        double argpm = argpdf, mm = xmdf, t2 = t * t;
        var nodem = nodedf + nodecf * t2;
        double tempa = 1 - cc1 * t, tempe = Tle.Bstar * cc4 * t, templ = t2cof * t2;
        if (!isimp)
        {
            var delomg = omgcof * t;
            var delm = xmcof * (Math.Pow(1 + eta * Math.Cos(xmdf), 3) - delmo);
            var tmp = delomg + delm;
            mm = xmdf + tmp; argpm = argpdf - tmp;
            double t3 = t2 * t, t4 = t3 * t;
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4;
            tempe += Tle.Bstar * cc5 * (Math.Sin(mm) - sinmao);
            templ += t3cof * t3 + t4 * (t4cof + t * t5cof);
        }
        var am = Math.Pow(Xke / noUnkozai, 2.0 / 3) * tempa * tempa;
        var nm = Xke / Math.Pow(am, 1.5);
        var em = Tle.Ecc - tempe;
        if (em >= 1 || em < -0.001 || am < 0.95) return null;
        if (em < 1e-6) em = 1e-6;
        mm += noUnkozai * templ;
        var xlm = mm + argpm + nodem;
        nodem %= twopi; argpm %= twopi; xlm %= twopi;
        mm = (xlm - argpm - nodem) % twopi;
        double sinip = Math.Sin(Tle.Incl), cosip = Math.Cos(Tle.Incl);
        var axnl = em * Math.Cos(argpm);
        var temp = 1 / (am * (1 - em * em));
        var aynl = em * Math.Sin(argpm) + temp * aycof;
        var xl = mm + argpm + nodem + temp * xlcof * axnl;
        var u = (xl - nodem) % twopi;
        double eo1 = u, tem5 = 9999.9, sineo1 = 0, coseo1 = 0;
        for (var ktr = 1; Math.Abs(tem5) >= 1e-12 && ktr <= 10; ktr++)
        {
            sineo1 = Math.Sin(eo1); coseo1 = Math.Cos(eo1);
            tem5 = 1 - coseo1 * axnl - sineo1 * aynl;
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5;
            if (Math.Abs(tem5) >= 0.95) tem5 = tem5 > 0 ? 0.95 : -0.95;
            eo1 += tem5;
        }
        double ecose = axnl * coseo1 + aynl * sineo1, esine = axnl * sineo1 - aynl * coseo1;
        double el2 = axnl * axnl + aynl * aynl, pl = am * (1 - el2);
        if (pl <= 0) return null;
        double rl = am * (1 - ecose), rdotl = Math.Sqrt(am) * esine / rl, rvdotl = Math.Sqrt(pl) / rl, betal = Math.Sqrt(1 - el2);
        temp = esine / (1 + betal);
        double sinu = am / rl * (sineo1 - aynl - axnl * temp), cosu = am / rl * (coseo1 - axnl + aynl * temp);
        var su = Math.Atan2(sinu, cosu);
        double sin2u = (cosu + cosu) * sinu, cos2u = 1 - 2 * sinu * sinu;
        temp = 1 / pl;
        double temp1 = 0.5 * J2 * temp, temp2 = temp1 * temp;
        var mrt = rl * (1 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u;
        su -= 0.25 * temp2 * x7thm1 * sin2u;
        var xnode = nodem + 1.5 * temp2 * cosip * sin2u;
        var xinc = Tle.Incl + 1.5 * temp2 * cosip * sinip * cos2u;
        var mvt = rdotl - nm * temp1 * x1mth2 * sin2u / Xke;
        var rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / Xke;
        double sinsu = Math.Sin(su), cossu = Math.Cos(su), snod = Math.Sin(xnode), cnod = Math.Cos(xnode), sini = Math.Sin(xinc), cosi = Math.Cos(xinc);
        double xmx = -snod * cosi, xmy = cnod * cosi;
        double ux = xmx * sinsu + cnod * cossu, uy = xmy * sinsu + snod * cossu, uz = sini * sinsu;
        double vx = xmx * cossu - cnod * sinsu, vy = xmy * cossu - snod * sinsu, vz = sini * cossu;
        if (mrt < 1) return null;
        var vk = Re * Xke / 60;
        return ((mrt * ux * Re, mrt * uy * Re, mrt * uz * Re),
                ((mvt * ux + rvdot * vx) * vk, (mvt * uy + rvdot * vy) * vk, (mvt * uz + rvdot * vz) * vk));
    }

    public (double X, double Y, double Z)? Position(DateTime utc) => Propagate((Astro.JulianDay(utc) - Tle.EpochJD) * 1440)?.R;
}

public sealed record SatellitePass(string Name, DateTime Rise, DateTime Peak, DateTime Set, double MaxAltitude,
                                   double RiseAzimuth, double SetAzimuth, bool Sunlit);

public static class Satellites
{
    public static double Gmst(double jd)
    {
        var t = (jd - 2451545.0) / 36525;
        var s = 67310.54841 + (876600.0 * 3600 + 8640184.812866) * t + 0.093104 * t * t - 6.2e-6 * t * t * t;
        s %= 86400; if (s < 0) s += 86400;
        return s / 240 * Math.PI / 180;
    }

    public static (double X, double Y, double Z) Observer(double lat, double lon, double h = 0.6)
    {
        const double a = 6378.137, f = 1 / 298.257223563;
        var e2 = f * (2 - f);
        double p = lat * Astro.Deg, l = lon * Astro.Deg;
        var n = a / Math.Sqrt(1 - e2 * Math.Sin(p) * Math.Sin(p));
        return ((n + h) * Math.Cos(p) * Math.Cos(l), (n + h) * Math.Cos(p) * Math.Sin(l), (n * (1 - e2) + h) * Math.Sin(p));
    }

    public static (double Alt, double Az, double Range) AltAz((double X, double Y, double Z) r, DateTime utc, double lat, double lon)
    {
        var g = Gmst(Astro.JulianDay(utc));
        double ex = r.X * Math.Cos(g) + r.Y * Math.Sin(g), ey = -r.X * Math.Sin(g) + r.Y * Math.Cos(g), ez = r.Z;
        var o = Observer(lat, lon);
        double dx = ex - o.X, dy = ey - o.Y, dz = ez - o.Z;
        double p = lat * Astro.Deg, l = lon * Astro.Deg;
        var s = Math.Sin(p) * Math.Cos(l) * dx + Math.Sin(p) * Math.Sin(l) * dy - Math.Cos(p) * dz;
        var e = -Math.Sin(l) * dx + Math.Cos(l) * dy;
        var z = Math.Cos(p) * Math.Cos(l) * dx + Math.Cos(p) * Math.Sin(l) * dy + Math.Sin(p) * dz;
        var range = Math.Sqrt(dx * dx + dy * dy + dz * dz);
        var az = Math.Atan2(e, -s) * Astro.Rad; if (az < 0) az += 360;
        return (Math.Asin(z / range) * Astro.Rad, az, range);
    }

    public static bool Sunlit((double X, double Y, double Z) r, DateTime utc)
    {
        var s = Astro.Sun(utc);
        double ra = s.Ra * 15 * Astro.Deg, dec = s.Dec * Astro.Deg;
        double ux = Math.Cos(dec) * Math.Cos(ra), uy = Math.Cos(dec) * Math.Sin(ra), uz = Math.Sin(dec);
        var along = r.X * ux + r.Y * uy + r.Z * uz;
        if (along > 0) return true;
        double px = r.X - along * ux, py = r.Y - along * uy, pz = r.Z - along * uz;
        return Math.Sqrt(px * px + py * py + pz * pz) > 6378.137;
    }

    public static bool SunlitAt(Tle t, DateTime utc) => Sgp4.Create(t)?.Position(utc) is { } r && Sunlit(r, utc);

    public static List<SatellitePass> Passes(Tle tle, DateTime startUtc, double days, double lat, double lon,
                                             double minAltitude = 10, bool onlyVisible = true)
    {
        var res = new List<SatellitePass>();
        if (Sgp4.Create(tle) is not Sgp4 sgp) return res;
        var t = startUtc; var end = startUtc.AddDays(days);
        var inPass = false; DateTime rise = t, peak = t; double maxAlt = -90, riseAz = 0, lastAz = 0; var peakSunlit = false;
        while (t < end)
        {
            if (onlyVisible && !inPass && Astro.SunAltitude(t, lat, lon) > -6) { t = t.AddSeconds(300); continue; }
            if (sgp.Position(t) is not { } r) break;
            var aa = AltAz(r, t, lat, lon);
            if (aa.Alt >= minAltitude)
            {
                if (!inPass) { inPass = true; rise = t; riseAz = aa.Az; maxAlt = -90; }
                if (aa.Alt > maxAlt) { maxAlt = aa.Alt; peak = t; peakSunlit = Sunlit(r, t); }
                lastAz = aa.Az;
            }
            else if (inPass)
            {
                inPass = false;
                if (peakSunlit || !onlyVisible) res.Add(new SatellitePass(tle.Name, rise, peak, t, maxAlt, riseAz, lastAz, peakSunlit));
            }
            t = t.AddSeconds(inPass ? 4 : (aa.Alt < -20 ? 60 : 20));
        }
        return res;
    }

    public static double AngularDistance(double alt1, double az1, double alt2, double az2)
    {
        var c = Math.Sin(alt1 * Astro.Deg) * Math.Sin(alt2 * Astro.Deg) + Math.Cos(alt1 * Astro.Deg) * Math.Cos(alt2 * Astro.Deg) * Math.Cos((az1 - az2) * Astro.Deg);
        return Math.Acos(Math.Clamp(c, -1, 1)) * Astro.Rad;
    }

    public static (double Sep, DateTime At)? ClosestApproach(Tle tle, double raHours, double decDeg, DateTime from, DateTime to, double lat, double lon)
    {
        if (Sgp4.Create(tle) is not Sgp4 sgp) return null;
        var target = Astro.PrecessFromJ2000(raHours, decDeg, from);
        (double, DateTime)? best = null;
        var t = from;
        while (t <= to)
        {
            double step = 30;
            if (sgp.Position(t) is not { } r) break;
            var s = AltAz(r, t, lat, lon);
            if (s.Alt < -30) step = 120;
            else if (s.Alt > -5)
            {
                var o = Astro.AltAz(target.Ra, target.Dec, t, lat, lon);
                var sep = AngularDistance(s.Alt, s.Az, o.Alt, o.Az);
                if (s.Alt > 0 && (best is null || sep < best.Value.Item1)) best = (sep, t);
                step = sep < 10 ? 0.25 : (sep < 40 ? 2 : 10);
            }
            t = t.AddSeconds(step);
        }
        return best is { } b ? (b.Item1, b.Item2) : null;
    }

    public static List<(string Name, DateTime At, double Sep)> Crossings(IEnumerable<Tle> tles, double raHours, double decDeg,
        DateTime from, DateTime to, double lat, double lon, double radius = 1.0) =>
        tles.Select(t => (t, c: ClosestApproach(t, raHours, decDeg, from, to, lat, lon)))
            .Where(x => x.c is { } c && c.Sep <= radius && SunlitAt(x.t, c.At))
            .Select(x => (x.t.Name, x.c!.Value.At, x.c!.Value.Sep)).OrderBy(x => x.At).ToList();

    public static bool IsCrewed(string name) => name.StartsWith("ISS (ZARYA)") || name.StartsWith("CSS (TIANHE)");

    /// <summary>Estaciones tripuladas: todos los pasos visibles; el resto, solo por encima de 40°.</summary>
    public static List<SatellitePass> Compute(IEnumerable<Tle> tles, double lat, double lon, DateTime fromUtc, double days = 5) =>
        tles.SelectMany(t => Passes(t, fromUtc, days, lat, lon).Where(p => IsCrewed(t.Name) || p.MaxAltitude >= 40))
            .OrderBy(p => p.Rise).Take(150).ToList();
}

/// <summary>Órbitas de CelesTrak (estaciones y satélites brillantes), por HTTPS, con límite de tamaño y caché diaria.</summary>
public sealed class SatelliteStore : Observable
{
    public static SatelliteStore Shared { get; } = new();
    public static readonly string[] Sources =
    [
        "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle",
        "https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=tle",
    ];
    public const int MaxBytes = 2_000_000;
    private readonly string _cache;
    private List<Tle> _tles = []; public List<Tle> Tles { get => _tles; private set => Set(ref _tles, value); }
    public DateTime? Updated { get; private set; }
    private string? _error; public string? Error { get => _error; private set => Set(ref _error, value); }

    public SatelliteStore(string? cache = null)
    {
        _cache = cache ?? Path.Combine(AppPaths.Data, "satellites.tle");
        try
        {
            var fi = new FileInfo(_cache);
            if (fi.Exists && fi.Length <= MaxBytes * 2) { Tles = Merge(Tle.ParseList(File.ReadAllText(_cache))); Updated = fi.LastWriteTime; }
        }
        catch { }
    }

    public static List<Tle> Merge(IEnumerable<Tle> list)
    {
        var seen = new HashSet<string>();
        string[] crewed = ["ISS (ZARYA)", "CSS (TIANHE)", "TIANGONG"];
        int Rank(Tle t) { var i = Array.FindIndex(crewed, c => t.Name.StartsWith(c)); return i < 0 ? 99 : i; }
        return list.Where(t => seen.Add(t.Line1[..7])).OrderBy(Rank).ThenBy(t => t.Name, StringComparer.Ordinal).ToList();
    }

    public static List<Tle>? Accept(byte[] data, Uri? url)
    {
        if (url is null || url.Scheme != "https" || url.Host != "celestrak.org" || data.Length > MaxBytes) return null;
        var list = Tle.ParseList(System.Text.Encoding.UTF8.GetString(data));
        return list.Count == 0 ? null : list;
    }

    public async Task RefreshIfNeeded(bool force = false)
    {
        if (!force && Updated is DateTime u && (DateTime.Now - u).TotalHours < 24 && Tles.Count > 0) return;
        var all = new List<Tle>();
        foreach (var src in Sources)
        {
            try
            {
                using var resp = await WeatherService.Http.GetAsync(src);
                if (!resp.IsSuccessStatusCode || resp.Content.Headers.ContentLength is > MaxBytes) continue;
                var bytes = await resp.Content.ReadAsByteArrayAsync();
                if (Accept(bytes, resp.RequestMessage?.RequestUri) is { } list) all.AddRange(list);
            }
            catch { }
        }
        if (all.Count == 0) { Error = Strings.T("No se pudieron descargar las órbitas de los satélites."); return; }
        try { File.WriteAllText(_cache, string.Concat(all.Select(t => $"{t.Name}\n{t.Line1}\n{t.Line2}\n"))); } catch { }
        Tles = Merge(all); Updated = DateTime.Now; Error = null;
    }
}
