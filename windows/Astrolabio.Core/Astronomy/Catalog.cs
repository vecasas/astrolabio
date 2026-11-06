using System.Globalization;
using System.Reflection;

namespace Astrolabio.Core.Astronomy;

public enum ObjectKind { Galaxy, Nebula, Planetary, Snr, Globular, Open, Other }

public static class ObjectKindExt
{
    /// <summary>Nombre en español (clave de traducción, igual que en macOS).</summary>
    public static string Key(this ObjectKind k) => k switch
    {
        ObjectKind.Galaxy => "Galaxia", ObjectKind.Nebula => "Nebulosa", ObjectKind.Planetary => "Nebulosa planetaria",
        ObjectKind.Snr => "Resto de supernova", ObjectKind.Globular => "Cúmulo globular", ObjectKind.Open => "Cúmulo abierto", _ => "Otro",
    };
    public static string Label(this ObjectKind k) => Strings.T(k.Key());
    public static bool WantsLP(this ObjectKind k) => k is ObjectKind.Nebula or ObjectKind.Snr or ObjectKind.Planetary;
}

public sealed record DeepSkyObject(string Id, string Name, ObjectKind Kind, double RaHours, double DecDeg, double Magnitude, double SizeArcmin)
{
    public string LocalizedName => Name.Length == 0 ? "" : Strings.T(Name);
    public string DisplayName => Name.Length == 0 ? Id : $"{Id} · {LocalizedName}";
}

/// <summary>Catálogo integrado (Messier y una selección de NGC, IC y Sharpless), el mismo que en macOS.</summary>
public static class Catalog
{
    public static readonly IReadOnlyList<DeepSkyObject> Objects = Load();

    private static List<DeepSkyObject> Load()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("Astrolabio.Core.Data.catalog.txt")!;
        using var r = new StreamReader(s);
        var list = new List<DeepSkyObject>();
        while (r.ReadLine() is { } line)
        {
            var f = line.Split('|');
            if (f.Length != 7) continue;
            var kind = f[2] switch { "G" => ObjectKind.Galaxy, "N" => ObjectKind.Nebula, "P" => ObjectKind.Planetary, "S" => ObjectKind.Snr, "GC" => ObjectKind.Globular, "OC" => ObjectKind.Open, _ => ObjectKind.Other };
            var ra = f[3].Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(x => double.Parse(x, CultureInfo.InvariantCulture)).ToArray();
            var neg = f[4].StartsWith('-');
            var de = f[4].Replace("+", "").Replace("-", "").Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(x => double.Parse(x, CultureInfo.InvariantCulture)).ToArray();
            if (ra.Length != 2 || de.Length != 2) continue;
            double.TryParse(f[5], NumberStyles.Float, CultureInfo.InvariantCulture, out var mag);
            double.TryParse(f[6], NumberStyles.Float, CultureInfo.InvariantCulture, out var size);
            list.Add(new DeepSkyObject(f[0], f[1], kind, ra[0] + ra[1] / 60, (de[0] + de[1] / 60) * (neg ? -1 : 1), mag == 0 ? 10 : mag, size == 0 ? 5 : size));
        }
        return list;
    }

    public static string Normalize(string s)
    {
        var d = s.Normalize(System.Text.NormalizationForm.FormD);
        return new string(d.Where(c => CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark && c != ' ').ToArray()).ToLowerInvariant();
    }

    public static DeepSkyObject? Find(string query)
    {
        var q = Normalize(query);
        return Objects.FirstOrDefault(o => Normalize(o.Id) == q || Normalize(o.Name) == q || (o.Name.Length > 0 && Normalize(Strings.T(o.Name)) == q));
    }
}

/// <summary>Estrellas, líneas y nombres de constelaciones para la carta estelar.</summary>
public static class SkyCatalog
{
    public sealed record Star(double Ra, double Dec, double Mag, double Bv, string Name);
    public sealed record Label(double Ra, double Dec, int Rank, string[] Names)
    {
        public string Name => Names.Length > (int)Strings.Language ? Names[(int)Strings.Language] : Names[0];
    }

    private static IEnumerable<string> Lines(string res)
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("Astrolabio.Core.Data." + res)!;
        using var r = new StreamReader(s);
        while (r.ReadLine() is { } l) if (l.Length > 0) yield return l;
    }

    private static double D(string s) => double.Parse(s, CultureInfo.InvariantCulture);

    public static readonly IReadOnlyList<Star> Stars = Lines("stars.txt").Select(l => l.Split(','))
        .Where(f => f.Length >= 5).Select(f => new Star(D(f[0]), D(f[1]), D(f[2]), double.TryParse(f[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var bv) ? bv : 0.6, f[4])).ToList();

    public static readonly IReadOnlyList<(double Ra, double Dec)[]> ConstellationLines = Lines("lines.txt").Select(l =>
        l[(l.IndexOf(':') + 1)..].Split(';').Select(p => p.Split(',')).Where(c => c.Length == 2).Select(c => (D(c[0]), D(c[1]))).ToArray())
        .Where(a => a.Length >= 2).ToList();

    public static readonly IReadOnlyList<Label> Labels = Lines("constellations.txt").Select(l => l.Split(',', 4))
        .Where(f => f.Length == 4).Select(f => new Label(D(f[0]), D(f[1]), int.TryParse(f[2], out var r) ? r : 3, f[3].Split('|'))).ToList();
}
