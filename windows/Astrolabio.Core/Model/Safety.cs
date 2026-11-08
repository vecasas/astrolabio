using Astrolabio.Core.Astronomy;

namespace Astrolabio.Core.Model;

/// <summary>Límites de seguridad del apuntado: nunca cerca del Sol ni demasiado bajo (igual que Safety.swift).</summary>
public static class GotoSafety
{
    /// <summary>La distancia mínima al Sol no puede bajar de aquí.</summary>
    public const double SunSeparationFloor = 15;

    public sealed record Limits(double Latitude, double Longitude, double MinAltitude = 15, double MinSunSeparation = 30);

    /// <summary>Motivo para no apuntar, o null si es seguro. Coordenadas de la fecha (RA en horas).</summary>
    public static string? Check(double raHours, double decDeg, DateTime utc, Limits limits)
    {
        var sun = Astro.Sun(utc);
        var sep = Astro.Separation(raHours, decDeg, sun.Ra, sun.Dec);
        var sunLimit = Math.Max(SunSeparationFloor, limits.MinSunSeparation);
        if (sep < sunLimit)
            return Strings.T("Bloqueado por seguridad: el objetivo está a %@° del Sol (mínimo %@°). Apuntar cerca del Sol puede dañar la cámara.",
                (int)Math.Round(sep), (int)sunLimit);
        var alt = Astro.AltAz(raHours, decDeg, utc, limits.Latitude, limits.Longitude).Alt;
        if (alt < limits.MinAltitude)
            return Strings.T("Bloqueado por seguridad: el objetivo está a %@° de altura (mínimo %@°).", (int)Math.Round(alt), (int)limits.MinAltitude);
        return null;
    }
}

public sealed class GotoBlockedException(string reason) : Exception(reason);

/// <summary>Estimación de la batería del Seestar a partir de las sesiones anteriores.</summary>
public static class BatteryEstimate
{
    public const double DefaultDrainPerHour = 15;
    public const double Reserve = 10;

    public static double DrainPerHour(IEnumerable<ObservationRecord> records)
    {
        var samples = records.Select(r =>
        {
            if (r.BatteryStart is not int b1 || r.BatteryEnd is not int b2 || b1 <= b2) return (double?)null;
            var hours = (r.End - r.Start).TotalHours;
            return hours >= 1.0 / 3 ? (b1 - b2) / hours : null;
        }).OfType<double>().OrderBy(x => x).ToList();
        if (samples.Count == 0) return DefaultDrainPerHour;
        var cut = samples.Count >= 5 ? samples.Skip(1).Take(samples.Count - 2).ToList() : samples;
        return Math.Clamp(cut.Average(), 3, 40);
    }

    public static double ExpectedAtEnd(int battery, double hours, double drain) => battery - hours * drain;

    public static bool IsEnough(int battery, bool charging, double hours, double drain) =>
        charging || ExpectedAtEnd(battery, hours, drain) >= Reserve;

    public static double PlanHours(IEnumerable<PlanItem> items) =>
        items.Where(i => i.Status is PlanItem.ItemStatus.Pending or PlanItem.ItemStatus.Running)
             .Sum(i => Math.Max(0, i.Minutes - (i.DoneSeconds ?? 0) / 60) + 6) / 60;
}

/// <summary>Como mucho un aviso de cada tipo cada <c>interval</c>.</summary>
public sealed class AlertLimiter(TimeSpan interval)
{
    private readonly Dictionary<string, DateTime> _last = new();

    public bool ShouldSend(string kind, DateTime now)
    {
        if (_last.TryGetValue(kind, out var t) && now - t < interval) return false;
        _last[kind] = now;
        return true;
    }
}

/// <summary>Decide si hay que volver a apuntar porque el objeto quedó descentrado.</summary>
public static class RecenterPolicy
{
    public const double ImplausibleDegrees = 3;
    public enum Decision { Centered, Recenter, Unreliable }

    public static double OffsetArcmin(double targetRa, double targetDec, double actualRa, double actualDec) =>
        Astro.Separation(targetRa, targetDec, actualRa, actualDec) * 60;

    public static Decision Decide(double offsetArcmin, double tolerance) =>
        offsetArcmin > ImplausibleDegrees * 60 ? Decision.Unreliable : offsetArcmin > tolerance ? Decision.Recenter : Decision.Centered;
}

public enum EndAction { Park, Shutdown, Nothing }

public static class EndActionExt
{
    public static string Label(this EndAction a) => Strings.T(a switch
    {
        EndAction.Park => "Aparcar el telescopio",
        EndAction.Shutdown => "Aparcar y apagar el telescopio",
        _ => "Dejarlo como está",
    });
}

/// <summary>Reparte el tiempo ya apilado entre los paneles para retomar el plan.</summary>
public static class PlanProgress
{
    public static double[] RemainingPerPanel(double totalSeconds, int panels, double done)
    {
        if (panels <= 0) return [];
        var per = totalSeconds / panels;
        return Enumerable.Range(0, panels).Select(i => Math.Max(0, Math.Min(per, i * per + per - done))).ToArray();
    }
}

/// <summary>Problemas que merecen un aviso al móvil.</summary>
public static class HealthCheck
{
    public const int LowBattery = 20;
    public const double LowStorageMB = 1000;
    public const double SilentAfterSeconds = 180;

    public sealed record Issue(string Kind, string Message);

    public static List<Issue> Issues(bool connected, int? battery, bool charging, double? freeMB, bool planRunning, double disconnectedFor, double? computerFreeMB = null)
    {
        var o = new List<Issue>();
        if (computerFreeMB is double cf && cf < LowStorageMB)
            o.Add(new("computer-disk", Strings.T("⚠️ Queda poco espacio en el disco del ordenador: %@ MB. No se podrán guardar imágenes ni informes.", (int)cf)));
        if (connected)
        {
            if (battery is int b && b <= LowBattery && !charging) o.Add(new("battery", Strings.T("⚠️ Batería del Seestar baja: %@ %%.", b)));
            if (freeMB is double f && f < LowStorageMB) o.Add(new("storage", Strings.T("⚠️ Queda poco espacio en el Seestar: %@ MB.", (int)f)));
        }
        else if (planRunning && disconnectedFor >= SilentAfterSeconds)
            o.Add(new("silent", Strings.T("⚠️ El Seestar no responde desde hace %@ min y hay un plan en marcha.", (int)(disconnectedFor / 60))));
        return o;
    }

    /// <summary>Espacio libre (MB) en el disco de una carpeta.</summary>
    public static double? FreeMB(string folder)
    {
        try { return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(folder))!).AvailableFreeSpace / 1048576.0; } catch { return null; }
    }
}
