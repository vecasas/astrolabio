using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

namespace Astrolabio.Core.Protocol;

public enum ConnectionState { Disconnected, Connecting, Connected, Failed }

public sealed record SeestarEvent(string Name, JsonObject Data, DateTime Received)
{
    public string? State => Data.Str("state");
}

public enum LogLevel { Info, Warning, Error, Traffic }
public sealed record LogEntry(DateTime Date, LogLevel Level, string Text);

public sealed class SeestarException(string message) : Exception(message);

/// <summary>
/// Conexión de control con el Seestar: JSON por TCP en el puerto 4700, un mensaje por línea
/// terminado en "\r\n". Las respuestas llevan el mismo id que la petición; los avisos del
/// telescopio llegan como objetos con la clave "Event". Todos los cambios de estado se publican
/// en el contexto de sincronización en el que se creó el cliente (el hilo de la interfaz).
/// </summary>
public sealed class SeestarClient : Observable
{
    public const int ControlPort = 4700;
    /// <summary>Puerto de control (solo cambia en las pruebas con un Seestar simulado).</summary>
    public int Port { get; set; } = ControlPort;

    private readonly SynchronizationContext? _ui = SynchronizationContext.Current;
    private TcpClient? _tcp;
    private NetworkStream? _stream;
    private CancellationTokenSource? _cts;
    private int _nextId = 10000;
    private readonly ConcurrentDictionary<int, (string Method, TaskCompletionSource<JsonObject> Tcs)> _pending = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private bool _userDisconnect;

    public Func<SeestarSigner?> SignerProvider { get; set; } = () => null;
    /// <summary>Límites de seguridad del apuntado (los pone la app con los ajustes).</summary>
    public Func<Model.GotoSafety.Limits?> GotoLimitsProvider { get; set; } = () => null;
    /// <summary>Tolerancia del recentrado en minutos de arco, o null si está desactivado.</summary>
    public Func<double?> RecenterToleranceProvider { get; set; } = () => null;
    /// <summary>Pregunta antes de interrumpir un apilado (la pone la interfaz).</summary>
    public Func<string, Task<bool>> ConfirmInterrupt { get; set; } = _ => Task.FromResult(true);

    private static readonly AsyncLocal<bool> _unattended = new();
    /// <summary>Verdadero dentro de la sesión automática: no se pide confirmación.</summary>
    public static bool Unattended { get => _unattended.Value; set => _unattended.Value = value; }

    private string? _stackState; public string? StackState { get => _stackState; private set => Set(ref _stackState, value); }
    public bool IsStacking => StackState is "working" or "start";
    /// <summary>Aumenta en cada conexión: si cambia durante un apilado, hay que volver a apuntar y apilar.</summary>
    public int ConnectionCount { get; private set; }

    /// <summary>Espera a que haya conexión (la reconexión es automática).</summary>
    public async Task<bool> WaitForConnection(double timeout, CancellationToken ct = default)
    {
        var deadline = DateTime.Now.AddSeconds(timeout);
        while (!IsConnected)
        {
            if (ct.IsCancellationRequested || DateTime.Now > deadline) return false;
            try { await Task.Delay(2000, ct); } catch { return false; }
        }
        return true;
    }

    // Estado publicado
    private ConnectionState _state; public ConnectionState State { get => _state; private set { if (Set(ref _state, value)) OnPropertyChanged(nameof(IsConnected)); } }
    private string _statusText = Strings.T("Desconectado"); public string StatusText { get => _statusText; private set => Set(ref _statusText, value); }
    public bool IsConnected => State == ConnectionState.Connected;
    private string _host = ""; public string Host { get => _host; private set => Set(ref _host, value); }
    private bool _auth; public bool IsAuthenticated { get => _auth; private set => Set(ref _auth, value); }
    private string _authMessage = ""; public string AuthMessage { get => _authMessage; private set => Set(ref _authMessage, value); }
    private int _fw; public int FirmwareVersion { get => _fw; private set => Set(ref _fw, value); }
    private string _fwText = ""; public string FirmwareText { get => _fwText; private set => Set(ref _fwText, value); }
    private string _name = ""; public string DeviceName { get => _name; private set => Set(ref _name, value); }
    private double? _ra; public double? Ra { get => _ra; private set => Set(ref _ra, value); }
    private double? _dec; public double? Dec { get => _dec; private set => Set(ref _dec, value); }
    private int? _battery; public int? Battery { get => _battery; private set => Set(ref _battery, value); }
    private string? _charger; public string? ChargerStatus { get => _charger; private set => Set(ref _charger, value); }
    private double? _temp; public double? Temperature { get => _temp; private set => Set(ref _temp, value); }
    private double? _free; public double? FreeStorageMB { get => _free; private set => Set(ref _free, value); }
    private bool _eq; public bool IsEquatorial { get => _eq; private set => Set(ref _eq, value); }
    private int? _focus; public int? FocuserPosition { get => _focus; private set => Set(ref _focus, value); }
    private int _stacked; public int StackedFrames { get => _stacked; private set => Set(ref _stacked, value); }
    private int _dropped; public int DroppedFrames { get => _dropped; private set => Set(ref _dropped, value); }
    private int? _expMs; public int? StackExposureMs { get => _expMs; private set => Set(ref _expMs, value); }
    private int? _gain; public int? CurrentGain { get => _gain; private set => Set(ref _gain, value); }
    private (int Lo, int Hi)? _gainRange; public (int Lo, int Hi)? GainRange { get => _gainRange; private set => Set(ref _gainRange, value); }
    private bool? _lp; public bool? LpFilter { get => _lp; private set => Set(ref _lp, value); }
    private string? _target; public string? ViewTarget { get => _target; private set => Set(ref _target, value); }

    public ObservableCollection<LogEntry> Log { get; } = new();
    public bool LogTraffic { get; set; }
    public Dictionary<string, SeestarEvent> LastEvents { get; } = new();
    public event Action<SeestarEvent>? EventReceived;

    private void Ui(Action a)
    {
        if (_ui is null || SynchronizationContext.Current == _ui) a(); else _ui.Post(_ => a(), null);
    }

    public void AddLog(string text, LogLevel level = LogLevel.Info)
    {
        if (level == LogLevel.Traffic && !LogTraffic) return;
        Ui(() =>
        {
            Log.Add(new LogEntry(DateTime.Now, level, text));
            while (Log.Count > 1500) Log.RemoveAt(0);
        });
    }

    // ---------------------------------------------------------------- Conexión

    public async Task ConnectAsync(string host)
    {
        _userDisconnect = false;
        CloseSocket();
        Host = host;
        State = ConnectionState.Connecting;
        StatusText = Strings.T("Conectando…");
        AddLog(Strings.T("Conectando con %@:%@…", host, Port));
        var tcp = new TcpClient { NoDelay = true };
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            await tcp.ConnectAsync(host, Port, timeout.Token);
        }
        catch (Exception e)
        {
            tcp.Dispose();
            State = ConnectionState.Failed;
            StatusText = Strings.T("Error: %@", Strings.T("no se pudo conectar con %@", host));
            AddLog(Strings.T("No se puede llegar al telescopio: %@", e.Message), LogLevel.Error);
            return;
        }
        tcp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
        _tcp = tcp;
        _stream = tcp.GetStream();
        _cts = new CancellationTokenSource();
        State = ConnectionState.Connected;
        ConnectionCount++;
        StatusText = Strings.T("Conectado");
        AddLog(Strings.T("Conectado a %@.", host));
        _ = Task.Run(() => ReadLoop(_stream, _cts.Token));
        await AfterConnect();
        _ = Task.Run(() => Heartbeat(_cts.Token));
    }

    public void Disconnect()
    {
        _userDisconnect = true;
        CloseSocket();
        State = ConnectionState.Disconnected;
        StatusText = Strings.T("Desconectado");
        AddLog(Strings.T("Desconectado."));
    }

    private void CloseSocket()
    {
        _cts?.Cancel();
        _cts = null;
        try { _stream?.Dispose(); _tcp?.Dispose(); } catch { }
        _stream = null; _tcp = null;
        IsAuthenticated = false;
        foreach (var (_, p) in _pending) p.Tcs.TrySetException(new SeestarException(Strings.T("No hay conexión con el telescopio.")));
        _pending.Clear();
    }

    private void HandleDrop(string reason)
    {
        if (_tcp is null) return;
        AddLog(Strings.T("Conexión perdida: %@", reason), LogLevel.Warning);
        CloseSocket();
        State = ConnectionState.Failed;
        StatusText = Strings.T("Error: %@", reason);
        if (!_userDisconnect && Host.Length > 0) _ = Task.Run(Reconnect);
    }

    private async Task Reconnect()
    {
        var delay = 3.0;
        var target = Host;
        while (!_userDisconnect && !IsConnected)
        {
            await Task.Delay(TimeSpan.FromSeconds(delay));
            if (_userDisconnect || IsConnected) return;
            AddLog(Strings.T("Reintentando la conexión…"));
            var tcs = new TaskCompletionSource();
            Ui(async () => { await ConnectAsync(target); tcs.SetResult(); });
            await tcs.Task;
            delay = Math.Min(delay * 2, 60);
        }
    }

    private async Task AfterConnect()
    {
        var signer = SignerProvider();
        if (signer is not null) await Authenticate(signer);
        else
        {
            AuthMessage = Strings.T("Sin clave PEM: con firmware reciente el telescopio puede ignorar las órdenes.");
            AddLog(AuthMessage, LogLevel.Warning);
        }
        await RefreshDeviceState();
    }

    // ---------------------------------------------------------------- Autenticación

    public async Task Authenticate(SeestarSigner signer)
    {
        try
        {
            var challenge = await Send("get_verify_str", timeout: 10);
            var text = challenge.Str("result.str");
            if (string.IsNullOrEmpty(text))
            {
                AuthMessage = Strings.T("El telescopio no envió el reto de autenticación (¿está ocupado?).");
                AddLog(AuthMessage, LogLevel.Warning);
                return;
            }
            var reply = await Send("verify_client", new JsonObject { ["sign"] = signer.Sign(text), ["data"] = text }, 10);
            var code = reply.Int("code") ?? -1;
            if (code == 0)
            {
                IsAuthenticated = true;
                AuthMessage = Strings.T("Autenticado");
                AddLog(Strings.T("Autenticación correcta."));
            }
            else
            {
                AuthMessage = Strings.T("El telescopio rechazó la clave (código %@).", code);
                AddLog(AuthMessage, LogLevel.Error);
            }
        }
        catch (Exception e)
        {
            AuthMessage = Strings.T("Fallo de autenticación: %@", e.Message);
            AddLog(AuthMessage, LogLevel.Error);
        }
    }

    // ---------------------------------------------------------------- Lectura

    private async Task ReadLoop(NetworkStream stream, CancellationToken ct)
    {
        var buffer = new byte[256 * 1024];
        var pending = new List<byte>();
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var n = await stream.ReadAsync(buffer, ct);
                if (n == 0) { Ui(() => HandleDrop(Strings.T("el telescopio cerró la conexión"))); return; }
                pending.AddRange(buffer.AsSpan(0, n).ToArray());
                while (true)
                {
                    var idx = IndexOfCrLf(pending);
                    if (idx < 0) break;
                    var line = Encoding.UTF8.GetString(pending.GetRange(0, idx).ToArray());
                    pending.RemoveRange(0, idx + 2);
                    if (line.Length > 0 && JsonPath.Parse(line) is JsonObject obj) Ui(() => HandleMessage(obj));
                }
                if (pending.Count > 4 * 1024 * 1024) pending.Clear();
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { if (!ct.IsCancellationRequested) Ui(() => HandleDrop(e.Message)); }
    }

    private static int IndexOfCrLf(List<byte> b)
    {
        for (var i = 0; i + 1 < b.Count; i++) if (b[i] == 13 && b[i + 1] == 10) return i;
        return -1;
    }

    private void HandleMessage(JsonObject msg)
    {
        if (LogTraffic) AddLog("← " + msg.ToJsonString(), LogLevel.Traffic);
        if (msg["Event"]?.GetValue<string>() is string name)
        {
            var ev = new SeestarEvent(name, msg, DateTime.Now);
            LastEvents[name] = ev;
            ApplyEvent(ev);
            EventReceived?.Invoke(ev);
            return;
        }
        if (msg.Str("method") == "scope_get_equ_coord" && msg.Num("result.ra") is double r && msg.Num("result.dec") is double d)
        {
            Ra = r; Dec = d;
        }
        if (msg.Int("id") is int id && _pending.TryRemove(id, out var p))
        {
            if (msg["error"] is JsonNode err)
                p.Tcs.TrySetException(new SeestarException(Strings.T("El telescopio devolvió un error (%@): %@", msg.Int("code") ?? -1, err.ToJsonString())));
            else p.Tcs.TrySetResult(msg);
        }
    }

    private void ApplyEvent(SeestarEvent e)
    {
        var d = e.Data;
        switch (e.Name)
        {
            case "Stack":
                if (e.State is string st) StackState = st;
                if (d.Int("stacked_frame") is int s) StackedFrames = s;
                if (d.Int("dropped_frame") is int x) DroppedFrames = x;
                break;
            case "PiStatus":
                if (d.Int("battery_capacity") is int b) Battery = b;
                if (d.Num("temp") is double t) Temperature = t;
                if (d.Str("charger_status") is string c) ChargerStatus = c;
                break;
            case "FocuserMove":
                if (d.Int("position") is int f) FocuserPosition = f;
                break;
        }
    }

    // ---------------------------------------------------------------- Envío

    public async Task<JsonObject> Send(string method, JsonNode? parameters = null, double timeout = 15)
    {
        var stream = _stream;
        if (stream is null || !IsConnected) throw new SeestarException(Strings.T("No hay conexión con el telescopio."));
        var id = Interlocked.Increment(ref _nextId);
        var message = new JsonObject { ["id"] = id, ["method"] = method };
        if (parameters is not null) message["params"] = parameters;
        message = WithVerify(message);
        var line = message.ToJsonString() + "\r\n";
        if (method != "scope_get_equ_coord") AddLog("→ " + line.Trim(), LogLevel.Traffic);
        var tcs = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = (method, tcs);
        try
        {
            await _writeLock.WaitAsync();
            try { await stream.WriteAsync(Encoding.UTF8.GetBytes(line)); } finally { _writeLock.Release(); }
        }
        catch (Exception e)
        {
            _pending.TryRemove(id, out _);
            throw new SeestarException(Strings.T("Error de red: %@", e.Message));
        }
        var done = await Task.WhenAny(tcs.Task, Task.Delay(TimeSpan.FromSeconds(timeout)));
        if (done != tcs.Task)
        {
            _pending.TryRemove(id, out _);
            throw new SeestarException(Strings.T("El telescopio no respondió a %@.", method));
        }
        return await tcs.Task;
    }

    /// <summary>
    /// Marcador "verify" que esperan algunas versiones del firmware:
    /// hasta 2582 no se usa; desde 2706 los parámetros objeto van tal cual; las listas lo llevan al
    /// final. get_albums no lo lleva: con él, el telescopio responde con una lista vacía.
    /// </summary>
    public JsonObject WithVerify(JsonObject message)
    {
        var method = message.Str("method") ?? "";
        if (method is "get_verify_str" or "verify_client" or "pi_is_verified" or "get_albums") return message;
        if (FirmwareVersion != 0 && FirmwareVersion <= 2582) return message;
        var p = message["params"];
        switch (p)
        {
            case null:
                message["params"] = new JsonArray("verify");
                break;
            case JsonObject o:
                if (FirmwareVersion >= 2706) break;
                o["verify"] = true;
                break;
            case JsonArray a:
                if (a.Count > 0 && a[^1]?.GetValueKind() == System.Text.Json.JsonValueKind.String && a[^1]!.GetValue<string>() == "verify") break;
                a.Add("verify");
                break;
            default:
                message["params"] = new JsonArray(p.DeepClone(), "verify");
                break;
        }
        return message;
    }

    // ---------------------------------------------------------------- Estado periódico

    private async Task Heartbeat(CancellationToken ct)
    {
        var tick = 0;
        var missed = 0;
        while (!ct.IsCancellationRequested && IsConnected)
        {
            try { await Send("scope_get_equ_coord", timeout: 8); missed = 0; }
            catch (Exception) when (!ct.IsCancellationRequested)
            {
                // Sin respuesta durante ~30 s (wifi caída o telescopio apagado sin cerrar la conexión).
                if (++missed >= 3) { Ui(() => HandleDrop(Strings.T("el telescopio no responde"))); return; }
            }
            if (tick % 10 == 0) await RefreshDeviceState();
            tick++;
            try { await Task.Delay(3000, ct); } catch { return; }
        }
    }

    public async Task RefreshDeviceState()
    {
        try
        {
            var r = await Send("get_device_state", timeout: 15);
            Ui(() =>
            {
                if (r.Int("result.device.firmware_ver_int") is int fw) FirmwareVersion = fw;
                if (r.Str("result.device.firmware_ver_string") is string fs) FirmwareText = fs;
                if (r.Str("result.device.name") is string n) DeviceName = n;
                if (r.Int("result.pi_status.battery_capacity") is int b) Battery = b;
                if (r.Num("result.pi_status.temp") is double t) Temperature = t;
                if (r.Str("result.pi_status.charger_status") is string c) ChargerStatus = c;
                if (r.Bool("result.mount.equ_mode") is bool eq) IsEquatorial = eq;
                if (r.Int("result.focuser.step") is int f) FocuserPosition = f;
                if (r.Num("result.storage.storage_volume.0.freeMB") is double free) FreeStorageMB = free;
            });
        }
        catch { }
        await RefreshSettings();
    }

    public async Task RefreshSettings()
    {
        try
        {
            var s = await Send("get_setting", timeout: 10);
            Ui(() =>
            {
                if (s.Int("result.exp_ms.stack_l") is int e) StackExposureMs = e;
                if (s.At("result.isp_range_gain") is JsonArray g && g.Count >= 2 && g[0] is not null && g[^1] is not null)
                    GainRange = ((int)g[0]!.GetValue<double>(), (int)g[^1]!.GetValue<double>());
            });
        }
        catch { }
        try
        {
            var v = await Send("get_view_state", timeout: 10);
            Ui(() =>
            {
                if (v.Str("result.View.target_name") is { Length: > 0 } t) ViewTarget = t;
                if (v.Int("result.View.gain") is int g) CurrentGain = g;
                if (v.Bool("result.View.lp_filter") is bool lp) LpFilter = lp;
                if (v.Int("result.View.Stack.stacked_frame") is int f) StackedFrames = f;
                if (v.Int("result.View.Stack.dropped_frame") is int d) DroppedFrames = d;
            });
        }
        catch { }
    }

    /// <summary>Espera a que el evento llegue con un estado final después de <paramref name="since"/>.</summary>
    public async Task<string?> WaitForEvent(string name, DateTime since, double timeout, CancellationToken ct = default)
    {
        var deadline = DateTime.Now.AddSeconds(timeout);
        DateTime? offline = null;
        while (DateTime.Now < deadline && !ct.IsCancellationRequested)
        {
            if (LastEvents.TryGetValue(name, out var ev) && ev.Received >= since && ev.State is "complete" or "fail" or "cancel")
                return ev.State;
            // Sin conexión más de 2 minutos: el evento ya no llegará.
            if (IsConnected) offline = null;
            else if (offline is DateTime o) { if ((DateTime.Now - o).TotalSeconds > 120) return null; }
            else offline = DateTime.Now;
            try { await Task.Delay(500, ct); } catch { return null; }
        }
        return null;
    }
}
