using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Astrolabio.Core.Model;

namespace Astrolabio.Core.Services;

/// <summary>Petición HTTP/1.1 mínima (una por conexión). Port de CompanionServer.swift.</summary>
public sealed record HttpRequestLite(string Method, string Path, Dictionary<string, string> Headers, byte[] Body)
{
    public const int MaxHeaderBytes = 8192, MaxBodyBytes = 2048;
    public enum Result { Incomplete, Invalid, Ok }

    public static (Result Result, HttpRequestLite? Request) Parse(byte[] data, int length)
    {
        var end = -1;
        for (var i = 0; i + 3 < length; i++)
            if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) { end = i; break; }
        if (end < 0) return (length > MaxHeaderBytes ? Result.Invalid : Result.Incomplete, null);
        if (end > MaxHeaderBytes) return (Result.Invalid, null);
        string head;
        try { head = new UTF8Encoding(false, true).GetString(data, 0, end); } catch { return (Result.Invalid, null); }
        var lines = head.Split("\r\n");
        var first = lines[0].Split(' ');
        if (first.Length != 3 || !first[2].StartsWith("HTTP/1.") || first[0] is not ("GET" or "POST" or "HEAD")
            || !first[1].StartsWith('/') || first[1].Length > 200) return (Result.Invalid, null);
        var headers = new Dictionary<string, string>();
        foreach (var l in lines.Skip(1))
        {
            var c = l.IndexOf(':');
            if (c < 0) return (Result.Invalid, null);
            headers[l[..c].Trim().ToLowerInvariant()] = l[(c + 1)..].Trim();
        }
        var len = headers.TryGetValue("content-length", out var cl) ? (int.TryParse(cl, out var n) ? n : -1) : 0;
        if (len < 0 || len > MaxBodyBytes || headers.ContainsKey("transfer-encoding")) return (Result.Invalid, null);
        var bodyStart = end + 4;
        if (length - bodyStart < len) return (Result.Incomplete, null);
        var path = first[1]; var q = path.IndexOf('?'); if (q >= 0) path = path[..q];
        return (Result.Ok, new HttpRequestLite(first[0], path, headers, data[bodyStart..(bodyStart + len)]));
    }
}

public sealed record HttpResponseLite(int Status, string ContentType, byte[] Body, Dictionary<string, string>? Extra = null)
{
    public static HttpResponseLite Json(int status, object obj) =>
        new(status, "application/json; charset=utf-8", JsonSerializer.SerializeToUtf8Bytes(obj));
    public static HttpResponseLite Error(int status, string message) => Json(status, new Dictionary<string, string> { ["error"] = message });

    public byte[] Serialize(bool head = false)
    {
        var reason = Status switch { 200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 429 => "Too Many Requests", _ => "Error" };
        var all = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["Cache-Control"] = "no-store", ["X-Content-Type-Options"] = "nosniff", ["X-Frame-Options"] = "DENY",
            ["Referrer-Policy"] = "no-referrer", ["Connection"] = "close",
        };
        if (Extra is not null) foreach (var (k, v) in Extra) all[k] = v;
        var sb = new StringBuilder($"HTTP/1.1 {Status} {reason}\r\nContent-Type: {ContentType}\r\nContent-Length: {Body.Length}\r\n");
        foreach (var (k, v) in all) sb.Append(k).Append(": ").Append(v.Replace("\r", " ").Replace("\n", " ")).Append("\r\n");
        sb.Append("\r\n");
        var h = Encoding.UTF8.GetBytes(sb.ToString());
        return head ? h : [.. h, .. Body];
    }
}

/// <summary>Emparejamiento (QR + código de 6 cifras, 5 minutos, 5 intentos) y llaves de los móviles (se guarda solo su SHA-256).</summary>
public sealed class CompanionAuth
{
    public sealed record Pairing(string Token, string Code, DateTime Expires) { public int Failures { get; set; } }
    public static readonly TimeSpan PairingLifetime = TimeSpan.FromMinutes(5);
    public const int MaxCodeFailures = 5;
    public enum PairResult { Ok, Expired, Wrong, Locked }

    public Pairing? Current { get; private set; }
    private readonly Dictionary<string, DateTime> _devices;
    public IReadOnlyDictionary<string, DateTime> Devices => _devices;
    public Action<IReadOnlyDictionary<string, DateTime>>? DevicesChanged { get; set; }
    public Func<DateTime> Now { get; set; } = () => DateTime.UtcNow;
    private readonly object _lock = new();

    public CompanionAuth(Dictionary<string, DateTime>? devices = null) => _devices = devices ?? [];

    public static string RandomToken(int bytes = 24) =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(bytes)).Replace('+', '-').Replace('/', '_').TrimEnd('=');
    public static string RandomCode() => RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
    public static string Hash(string key) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant();
    public static bool Same(string a, string b) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(a), Encoding.UTF8.GetBytes(b));

    public Pairing StartPairing() { lock (_lock) return Current = new Pairing(RandomToken(), RandomCode(), Now() + PairingLifetime); }
    public void CancelPairing() { lock (_lock) Current = null; }

    public (PairResult Result, string? Key) Pair(string token, string code)
    {
        lock (_lock)
        {
            if (Current is not { } p || Now() >= p.Expires) { Current = null; return (PairResult.Expired, null); }
            if (!Same(p.Token, token)) return (PairResult.Wrong, null);
            if (!Same(p.Code, code))
            {
                p.Failures++;
                if (p.Failures >= MaxCodeFailures) { Current = null; return (PairResult.Locked, null); }
                return (PairResult.Wrong, null);
            }
            Current = null;                       // un QR, un móvil
            var key = RandomToken(32);
            _devices[Hash(key)] = Now();
            DevicesChanged?.Invoke(_devices);
            return (PairResult.Ok, key);
        }
    }

    public bool IsAuthorized(string? authorization)
    {
        if (authorization is null || !authorization.StartsWith("Bearer ")) return false;
        var key = authorization[7..].Trim();
        if (key.Length is < 32 or > 64) return false;
        var h = Hash(key);
        lock (_lock) return _devices.Keys.Any(k => Same(k, h));
    }

    public void RevokeAll() { lock (_lock) { _devices.Clear(); Current = null; } DevicesChanged?.Invoke(_devices); }
}

/// <summary>Límite de peticiones por dirección (cubo de fichas).</summary>
public sealed class RateLimiter(double capacity, double perSecond)
{
    private readonly Dictionary<string, (double Tokens, DateTime At)> _b = [];
    public Func<DateTime> Now { get; set; } = () => DateTime.UtcNow;

    public bool Allow(string who, double cost = 1)
    {
        lock (_b)
        {
            var t = Now();
            (double Tokens, DateTime At) b = _b.TryGetValue(who, out var x) ? x : (capacity, t);
            b.Tokens = Math.Min(capacity, b.Tokens + (t - b.At).TotalSeconds * perSecond); b.At = t;
            var ok = b.Tokens >= cost;
            if (ok) b.Tokens -= cost;
            _b[who] = b;
            if (_b.Count > 256) foreach (var k in _b.Where(kv => (t - kv.Value.At).TotalMinutes > 10).Select(kv => kv.Key).ToList()) _b.Remove(k);
            return ok;
        }
    }
}

/// <summary>Lo que el móvil puede ver y hacer (lo rellena la app; en las pruebas, un simulacro).</summary>
public sealed record CompanionBridge(Func<Dictionary<string, object?>> Status, Func<byte[]?> Jpeg,
    Func<Task<string>> Stop, Func<Task<string>> Skip, Func<Task<string>> Park, Func<string> Language);

public sealed class CompanionRouter(CompanionAuth auth, CompanionBridge bridge, string expectedHost)
{
    public string ExpectedHost { get; set; } = expectedHost;
    private readonly RateLimiter _general = new(30, 3), _pair = new(5, 1.0 / 60), _actions = new(3, 0.1);

    public static bool IsPrivate(string ip)
    {
        var a = ip.ToLowerInvariant();
        var pct = a.IndexOf('%'); if (pct >= 0) a = a[..pct];
        if (a.StartsWith("::ffff:")) a = a[7..];
        if (a == "::1") return true;
        if (a.Contains(':')) return a.StartsWith("fe8") || a.StartsWith("fe9") || a.StartsWith("fea") || a.StartsWith("feb") || a.StartsWith("fc") || a.StartsWith("fd");
        var p = a.Split('.');
        if (p.Length != 4 || !p.All(x => int.TryParse(x, out var v) && v is >= 0 and <= 255 && x.Length is > 0 and <= 3)) return false;
        int p0 = int.Parse(p[0]), p1 = int.Parse(p[1]);
        return p0 == 10 || p0 == 127 || (p0 == 192 && p1 == 168) || (p0 == 172 && p1 is >= 16 and <= 31) || (p0 == 169 && p1 == 254);
    }

    public static Dictionary<string, string> PageStrings() => new()
    {
        ["lTarget"] = Strings.T("Objeto"), ["lPhase"] = Strings.T("Estado"), ["lFrames"] = Strings.T("Fotogramas"), ["lBattery"] = Strings.T("Batería"),
        ["lPlan"] = Strings.T("Plan"), ["lLog"] = Strings.T("Últimos mensajes"), ["stop"] = Strings.T("Parar"), ["skip"] = Strings.T("Saltar"), ["park"] = Strings.T("Aparcar"),
        ["pairText"] = Strings.T("Escribe el código de 6 cifras que aparece en el ordenador."), ["pairBtn"] = Strings.T("Emparejar"),
        ["needQR"] = Strings.T("Escanea el QR que aparece en Astrolabio, en «Control desde el móvil»."),
        ["pairFail"] = Strings.T("No se pudo emparejar."), ["offline"] = Strings.T("Sin conexión con el ordenador."),
        ["noScope"] = Strings.T("El telescopio no está conectado."), ["updated"] = Strings.T("Actualizada a las"),
        ["askStop"] = Strings.T("¿Parar el apilado o la sesión automática?"), ["askSkip"] = Strings.T("¿Saltar al siguiente objeto del plan?"),
        ["askPark"] = Strings.T("¿Parar y aparcar el telescopio?"), ["nightMode"] = Strings.T("Modo nocturno"), ["dayMode"] = Strings.T("Modo normal"),
    };

    private static string? _template;
    public static string Template
    {
        get
        {
            if (_template is not null) return _template;
            using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("Astrolabio.Core.Data.companion.html")!;
            return _template = new StreamReader(s).ReadToEnd();
        }
    }

    public async Task<HttpResponseLite> Handle(HttpRequestLite r, string ip)
    {
        if (!IsPrivate(ip)) return HttpResponseLite.Error(403, "Solo red local");
        if (!r.Headers.TryGetValue("host", out var host) || !string.Equals(host, ExpectedHost, StringComparison.OrdinalIgnoreCase)) return HttpResponseLite.Error(403, "Host");
        if (!_general.Allow(ip)) return HttpResponseLite.Error(429, Strings.T("Demasiadas peticiones. Espera un momento."));
        switch (r.Method, r.Path)
        {
            case ("GET" or "HEAD", "/"):
                return Page();
            case ("POST", "/api/pair"):
            {
                if (!_pair.Allow(ip)) return HttpResponseLite.Error(429, Strings.T("Demasiados intentos. Espera unos minutos."));
                string? token = null, code = null;
                try
                {
                    if (r.Headers.GetValueOrDefault("content-type")?.StartsWith("application/json") == true && JsonNode.Parse(r.Body) is JsonObject o)
                    { token = (string?)o["pair"]; code = (string?)o["code"]; }
                }
                catch { }
                if (token is null || code is null) return HttpResponseLite.Error(400, "JSON");
                var (res, key) = auth.Pair(token, code.Trim());
                return res switch
                {
                    CompanionAuth.PairResult.Ok => HttpResponseLite.Json(200, new Dictionary<string, string> { ["key"] = key! }),
                    CompanionAuth.PairResult.Wrong => HttpResponseLite.Error(401, Strings.T("Código incorrecto.")),
                    CompanionAuth.PairResult.Locked => HttpResponseLite.Error(401, Strings.T("Demasiados códigos incorrectos: vuelve a mostrar el QR en el ordenador.")),
                    _ => HttpResponseLite.Error(401, Strings.T("El QR ha caducado: vuelve a mostrarlo en el ordenador.")),
                };
            }
            case (_, var p) when p.StartsWith("/api/"):
                if (!auth.IsAuthorized(r.Headers.GetValueOrDefault("authorization"))) return HttpResponseLite.Error(401, Strings.T("Este móvil no está emparejado."));
                switch (r.Method, p)
                {
                    case ("GET", "/api/status"): return HttpResponseLite.Json(200, bridge.Status());
                    case ("GET", "/api/image.jpg"):
                        return bridge.Jpeg() is { } jpg ? new HttpResponseLite(200, "image/jpeg", jpg) : HttpResponseLite.Error(404, Strings.T("Sin imagen"));
                    case ("POST", "/api/stop" or "/api/skip" or "/api/park"):
                        if (!_actions.Allow(ip)) return HttpResponseLite.Error(429, Strings.T("Demasiadas peticiones. Espera un momento."));
                        var msg = p switch { "/api/stop" => await bridge.Stop(), "/api/skip" => await bridge.Skip(), _ => await bridge.Park() };
                        return HttpResponseLite.Json(200, new Dictionary<string, string> { ["message"] = msg });
                    default: return HttpResponseLite.Error(404, "No encontrado");
                }
            default:
                return HttpResponseLite.Error(r.Method == "GET" ? 404 : 405, "No encontrado");
        }
    }

    private HttpResponseLite Page()
    {
        var nonce = CompanionAuth.RandomToken(16);
        var json = JsonSerializer.Serialize(PageStrings()).Replace("<", "\\u003c").Replace(">", "\\u003e").Replace("&", "\\u0026");
        var html = Template.Replace("__NONCE__", nonce).Replace("__LANG__", bridge.Language()).Replace("__I18N__", json);
        return new HttpResponseLite(200, "text/html; charset=utf-8", Encoding.UTF8.GetBytes(html), new Dictionary<string, string>
        {
            ["Content-Security-Policy"] = $"default-src 'none'; script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'; img-src blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        });
    }
}

/// <summary>Servidor HTTP en la red local para el móvil. Apagado salvo que el usuario lo active.</summary>
public sealed class CompanionServer : Observable
{
    public static CompanionServer Shared { get; } = new();
    public const int DefaultPort = 8642;
    private readonly string _devicesFile;
    public CompanionAuth Auth { get; }
    private CompanionRouter? _router;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;

    private bool _running; public bool IsRunning { get => _running; private set => Set(ref _running, value); }
    private string? _url; public string? Url { get => _url; private set => Set(ref _url, value); }
    private string? _error; public string? Error { get => _error; private set => Set(ref _error, value); }
    private CompanionAuth.Pairing? _pairing; public CompanionAuth.Pairing? Pairing { get => _pairing; private set => Set(ref _pairing, value); }
    private int _devices; public int DeviceCount { get => _devices; private set => Set(ref _devices, value); }

    public CompanionServer(string? devicesFile = null)
    {
        _devicesFile = devicesFile ?? Path.Combine(AppPaths.Data, "companion-devices.json");
        Dictionary<string, DateTime> saved = [];
        try { if (File.Exists(_devicesFile)) saved = JsonSerializer.Deserialize<Dictionary<string, DateTime>>(File.ReadAllText(_devicesFile)) ?? []; } catch { }
        Auth = new CompanionAuth(saved);
        DeviceCount = saved.Count;
        Auth.DevicesChanged = d =>
        {
            try { File.WriteAllText(_devicesFile, JsonSerializer.Serialize(d)); } catch { }
            DeviceCount = d.Count;
        };
    }

    /// <summary>Primera IPv4 privada de una interfaz activa (wifi o cable).</summary>
    public static string? LanAddress()
    {
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()
                         .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType is NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet)
                         .OrderBy(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? 0 : 1))
                foreach (var a in ni.GetIPProperties().UnicastAddresses)
                    if (a.Address.AddressFamily == AddressFamily.InterNetwork && CompanionRouter.IsPrivate(a.Address.ToString()) && !a.Address.ToString().StartsWith("169.254."))
                        return a.Address.ToString();
        }
        catch { }
        return null;
    }

    public void Start(CompanionBridge bridge, int port = DefaultPort, string? bindAddress = null)
    {
        Stop();
        var ip = bindAddress ?? LanAddress();
        if (ip is null) { Error = Strings.T("No hay conexión a una red local."); return; }
        try
        {
            var l = new TcpListener(IPAddress.Parse(ip), port);
            l.Start();
            _listener = l; _cts = new CancellationTokenSource();
            _router = new CompanionRouter(Auth, bridge, $"{ip}:{port}");
            Url = $"http://{ip}:{port}/"; IsRunning = true; Error = null;
            _ = AcceptLoop(l, _router, _cts.Token);
        }
        catch (Exception e) { Error = e.Message; IsRunning = false; }
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _listener?.Stop(); } catch { }
        _listener = null; _router = null; _cts = null;
        IsRunning = false; Url = null; Pairing = null; Auth.CancelPairing();
    }

    public void StartPairing() => Pairing = Auth.StartPairing();
    public void CancelPairing() { Auth.CancelPairing(); Pairing = null; }
    public void RevokeAll() { Auth.RevokeAll(); Pairing = null; }
    public string? PairingUrl => Url is not null && Pairing is { } p ? $"{Url}#p={p.Token}" : null;

    private static async Task AcceptLoop(TcpListener l, CompanionRouter router, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await l.AcceptTcpClientAsync(ct); } catch { return; }
            _ = Serve(c, router);
        }
    }

    private static async Task Serve(TcpClient c, CompanionRouter router)
    {
        using var client = c;
        var ip = (c.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? "";
        if (!CompanionRouter.IsPrivate(ip)) return;      // fuera de la red local: se cierra sin leer
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            var s = c.GetStream();
            var buf = new byte[HttpRequestLite.MaxHeaderBytes + HttpRequestLite.MaxBodyBytes + 8];
            var n = 0;
            while (true)
            {
                var r = await s.ReadAsync(buf.AsMemory(n), cts.Token);
                n += r;
                var (res, req) = HttpRequestLite.Parse(buf, n);
                if (res == HttpRequestLite.Result.Ok)
                {
                    var resp = await router.Handle(req!, ip);
                    await s.WriteAsync(resp.Serialize(req!.Method == "HEAD"), cts.Token);
                    return;
                }
                if (res == HttpRequestLite.Result.Invalid || r == 0 || n >= buf.Length)
                {
                    await s.WriteAsync(HttpResponseLite.Error(400, "Bad request").Serialize(), cts.Token);
                    return;
                }
            }
        }
        catch { }
    }
}
