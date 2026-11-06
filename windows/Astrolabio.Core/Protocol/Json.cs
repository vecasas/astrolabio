using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Astrolabio.Core.Protocol;

/// <summary>Lectura cómoda de valores anidados con rutas tipo "result.device.name".</summary>
public static class JsonPath
{
    public static JsonNode? At(this JsonNode? node, string path)
    {
        var cur = node;
        foreach (var part in path.Split('.'))
        {
            if (cur is JsonObject o && o.TryGetPropertyValue(part, out var next)) cur = next;
            else if (cur is JsonArray a && int.TryParse(part, out var i) && i >= 0 && i < a.Count) cur = a[i];
            else return null;
        }
        return cur;
    }

    public static string? Str(this JsonNode? node, string path)
    {
        var v = node.At(path);
        if (v is not JsonValue jv) return null;
        if (jv.TryGetValue<string>(out var s)) return s;
        return jv.ToJsonString().Trim('"');
    }

    public static double? Num(this JsonNode? node, string path)
    {
        var v = node.At(path);
        if (v is not JsonValue jv) return null;
        if (jv.TryGetValue<double>(out var d)) return d;
        if (jv.TryGetValue<long>(out var l)) return l;
        if (jv.TryGetValue<string>(out var s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var p)) return p;
        return null;
    }

    public static int? Int(this JsonNode? node, string path) => node.Num(path) is double d ? (int)d : null;

    public static bool? Bool(this JsonNode? node, string path)
    {
        var v = node.At(path);
        if (v is not JsonValue jv) return null;
        if (jv.TryGetValue<bool>(out var b)) return b;
        if (jv.TryGetValue<long>(out var l)) return l != 0;
        if (jv.TryGetValue<string>(out var s)) return s is "true" or "1";
        return null;
    }

    public static JsonObject? Parse(string line)
    {
        try { return JsonNode.Parse(line) as JsonObject; } catch (JsonException) { return null; }
    }
}
