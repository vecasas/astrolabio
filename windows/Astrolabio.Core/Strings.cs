using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Astrolabio.Core;

public enum AppLanguage { es, en, fr, de, zh, ru }

/// <summary>
/// Traducciones compartidas con la versión de macOS: la clave es el texto en español y las tablas
/// (Data/translations.json) se generan desde scripts/i18n/*.tsv. Los huecos usan el formato de
/// Apple (%@, %d, %.1f, %1$@…) y se rellenan aquí.
/// </summary>
public static partial class Strings
{
    private static readonly Dictionary<string, Dictionary<string, string>> Tables = Load();
    public static AppLanguage Language { get; private set; } = SystemDefault();
    public static event Action? LanguageChanged;

    public static readonly (AppLanguage Lang, string Native)[] Languages =
    [
        (AppLanguage.es, "Español"), (AppLanguage.en, "English"), (AppLanguage.fr, "Français"),
        (AppLanguage.de, "Deutsch"), (AppLanguage.zh, "中文"), (AppLanguage.ru, "Русский"),
    ];

    public static CultureInfo Culture => Language == AppLanguage.zh ? new CultureInfo("zh-Hans") : new CultureInfo(Language.ToString());

    public static void SetLanguage(AppLanguage lang)
    {
        Language = lang;
        LanguageChanged?.Invoke();
    }

    public static AppLanguage SystemDefault()
    {
        var code = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        return Enum.TryParse<AppLanguage>(code, out var l) ? l : AppLanguage.es;
    }

    private static Dictionary<string, Dictionary<string, string>> Load()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("Astrolabio.Core.Data.translations.json");
        if (s is null) return new();
        return JsonSerializer.Deserialize<Dictionary<string, Dictionary<string, string>>>(s) ?? new();
    }

    public static string T(string key)
    {
        if (Language == AppLanguage.es) return key;
        return Tables.TryGetValue(Language.ToString(), out var t) && t.TryGetValue(key, out var v) ? v : key;
    }

    public static string T(string key, params object?[] args) => Format(T(key), args);

    public static IEnumerable<string> Missing(IEnumerable<string> keys, AppLanguage lang) =>
        keys.Where(k => !(Tables.TryGetValue(lang.ToString(), out var t) && t.ContainsKey(k)));

    [GeneratedRegex(@"%(?:(\d+)\$)?([-+#0]*)(\d*)(?:\.(\d+))?([@dfi])|%%")]
    private static partial Regex Spec();

    /// <summary>Rellena huecos con el formato de Apple usando números con punto decimal.</summary>
    public static string Format(string fmt, params object?[] args)
    {
        var next = 0;
        return Spec().Replace(fmt, m =>
        {
            if (m.Value == "%%") return "%";
            var index = m.Groups[1].Success ? int.Parse(m.Groups[1].Value) - 1 : next++;
            var arg = index < args.Length ? args[index] : null;
            var kind = m.Groups[5].Value;
            var precision = m.Groups[4].Success ? int.Parse(m.Groups[4].Value) : (int?)null;
            return kind switch
            {
                "@" => Convert.ToString(arg, CultureInfo.InvariantCulture) ?? "",
                "d" or "i" => Convert.ToInt64(arg ?? 0, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture),
                _ => Convert.ToDouble(arg ?? 0, CultureInfo.InvariantCulture).ToString("F" + (precision ?? 6), CultureInfo.InvariantCulture),
            };
        });
    }
}
