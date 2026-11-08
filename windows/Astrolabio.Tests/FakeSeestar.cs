using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Astrolabio.Tests;

/// <summary>Seestar simulado (igual que FakeSeestar.swift): protocolo JSON por TCP en 127.0.0.1.</summary>
public sealed class FakeSeestar : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _cts = new();
    private NetworkStream? _stream;
    private readonly SemaphoreSlim _write = new(1, 1);
    private (double Ra, double Dec)? _target;
    private double _offset;

    public int Port { get; }
    public ConcurrentQueue<string> Received { get; } = new();
    public RSA? PublicKey { get; set; }
    public Queue<double> PointingOffsetsArcmin { get; } = new();
    public Dictionary<string, int> Errors { get; } = new();
    public HashSet<string> Silent { get; } = [];
    public HashSet<string> DropOn { get; } = [];

    public int Count(string m) => Received.Count(x => x == m);

    public FakeSeestar()
    {
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _ = Task.Run(AcceptLoop);
    }

    private async Task AcceptLoop()
    {
        while (!_cts.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await _listener.AcceptTcpClientAsync(_cts.Token); } catch { return; }
            _stream = c.GetStream();
            _ = Task.Run(() => ReadLoop(c));
        }
    }

    private async Task ReadLoop(TcpClient c)
    {
        var s = c.GetStream();
        var buf = new byte[65536];
        var pending = new StringBuilder();
        try
        {
            while (true)
            {
                var n = await s.ReadAsync(buf, _cts.Token);
                if (n == 0) return;
                pending.Append(Encoding.UTF8.GetString(buf, 0, n));
                string text;
                while ((text = pending.ToString()).Contains("\r\n"))
                {
                    var i = text.IndexOf("\r\n", StringComparison.Ordinal);
                    pending.Remove(0, i + 2);
                    if (JsonNode.Parse(text[..i]) is JsonObject msg) await Handle(c, msg);
                }
            }
        }
        catch { }
    }

    private async Task Write(JsonObject o)
    {
        if (_stream is null) return;
        await _write.WaitAsync();
        try { await _stream.WriteAsync(Encoding.UTF8.GetBytes(o.ToJsonString() + "\r\n")); } catch { } finally { _write.Release(); }
    }

    private Task Reply(int id, string method, JsonNode? result = null) =>
        Write(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method, ["result"] = result ?? 0, ["code"] = 0 });

    public Task Emit(JsonObject ev) => Write(ev);

    private async Task Handle(TcpClient c, JsonObject msg)
    {
        var method = msg["method"]?.GetValue<string>() ?? "";
        var id = msg["id"]?.GetValue<int>() ?? 0;
        var p = msg["params"];
        Received.Enqueue(method);
        if (DropOn.Contains(method)) { c.Close(); _stream = null; return; }
        if (Silent.Contains(method)) return;
        if (Errors.TryGetValue(method, out var code))
        {
            await Write(new JsonObject { ["id"] = id, ["method"] = method, ["code"] = code, ["error"] = "fallo simulado" });
            return;
        }
        switch (method)
        {
            case "get_verify_str":
                await Reply(id, method, new JsonObject { ["str"] = "reto-de-prueba-123" });
                break;
            case "verify_client":
                var ok = true;
                if (PublicKey is not null)
                {
                    var sig = Convert.FromBase64String(p?["sign"]?.GetValue<string>() ?? "");
                    var data = Encoding.UTF8.GetBytes(p?["data"]?.GetValue<string>() ?? "");
                    ok = PublicKey.VerifyData(data, sig, HashAlgorithmName.SHA1, RSASignaturePadding.Pkcs1);
                }
                if (ok) await Reply(id, method);
                else await Write(new JsonObject { ["id"] = id, ["method"] = method, ["code"] = 210, ["error"] = "fail to verify" });
                break;
            case "get_device_state":
                await Reply(id, method, JsonNode.Parse("""
                    {"device":{"firmware_ver_int":2706,"firmware_ver_string":"6.45","name":"Seestar S50 simulado"},
                     "pi_status":{"battery_capacity":87,"temp":21.5,"charger_status":"Discharging"},
                     "mount":{"equ_mode":false},"focuser":{"step":1600},"storage":{"storage_volume":[{"freeMB":12000}]}}
                    """));
                break;
            case "iscope_start_view":
                if (p?["target_ra_dec"] is JsonArray rd) _target = (rd[0]!.GetValue<double>(), rd[1]!.GetValue<double>());
                _offset = PointingOffsetsArcmin.Count > 0 ? PointingOffsetsArcmin.Dequeue() : 0;
                await Reply(id, method);
                _ = Task.Run(async () =>
                {
                    await Task.Delay(200); await Write(new JsonObject { ["Event"] = "AutoGoto", ["state"] = "start" });
                    await Task.Delay(200); await Write(new JsonObject { ["Event"] = "AutoGoto", ["state"] = "complete" });
                });
                break;
            case "scope_get_equ_coord":
                var t = _target ?? (0, 0);
                await Reply(id, method, new JsonObject { ["ra"] = t.Ra, ["dec"] = t.Dec + _offset / 60 });
                break;
            case "iscope_start_stack":
                await Reply(id, method);
                await Write(new JsonObject { ["Event"] = "Stack", ["state"] = "working", ["stacked_frame"] = 1 });
                break;
            default:
                await Reply(id, method);
                break;
        }
    }

    public void Dispose() { _cts.Cancel(); try { _listener.Stop(); } catch { } }
}

/// <summary>Canal de imagen simulado: al conectar envía una imagen apilada (ZIP con raw_data).</summary>
public sealed class FakeImageServer : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    public int Port { get; }

    public FakeImageServer(int width = 64, int height = 48)
    {
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _ = Task.Run(async () =>
        {
            try
            {
                var c = await _listener.AcceptTcpClientAsync();
                await Task.Delay(300);
                await c.GetStream().WriteAsync(Frame(width, height));
            }
            catch { }
        });
    }

    public static byte[] Frame(int w, int h)
    {
        var raw = new byte[w * h * 6];
        for (var i = 0; i < w * h * 3; i++) BitConverter.TryWriteBytes(raw.AsSpan(i * 2), (ushort)(1000 + i % 3 * 500));
        using var ms = new MemoryStream();
        using (var z = new System.IO.Compression.ZipArchive(ms, System.IO.Compression.ZipArchiveMode.Create, true))
        using (var s = z.CreateEntry("raw_data", System.IO.Compression.CompressionLevel.NoCompression).Open()) s.Write(raw);
        var zip = ms.ToArray();
        var hdr = new byte[80];
        hdr[6] = (byte)(zip.Length >> 24); hdr[7] = (byte)(zip.Length >> 16); hdr[8] = (byte)(zip.Length >> 8); hdr[9] = (byte)zip.Length;
        hdr[15] = 23;
        hdr[16] = (byte)(w >> 8); hdr[17] = (byte)w; hdr[18] = (byte)(h >> 8); hdr[19] = (byte)h;
        return [.. hdr, .. zip];
    }

    public void Dispose() { try { _listener.Stop(); } catch { } }
}
