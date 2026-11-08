using System.IO.Compression;
using System.Net.Sockets;
using System.Text;
using Astrolabio.Core.Imaging;

namespace Astrolabio.Core.Protocol;

/// <summary>
/// Canal de imagen del Seestar (TCP 4800): cabecera binaria de 80 bytes (big-endian: tamaño en los
/// bytes 6–9, id en el 15, ancho y alto en 16–19) seguida de los datos. id 21 = vista previa
/// (Bayer 16 bits), id 23 = apilado en un ZIP con "raw_data" (RGB 16 bits). Se reconecta solo.
/// </summary>
public sealed class ImageStream
{
    public const int Port = 4800;
    public event Action<RawFrame>? FrameReceived;
    public event Action<string>? StatusChanged;
    public event Action? Ready;

    private TcpClient? _tcp;
    private NetworkStream? _stream;
    private CancellationTokenSource? _cts;
    private string _host = "";
    private volatile bool _want;
    public bool IsReady { get; private set; }

    public void Connect(string host)
    {
        if (_want && _host == host && _tcp is not null) return;
        _want = true;
        _host = host;
        _ = Task.Run(() => Open(host));
    }

    public void Disconnect()
    {
        _want = false;
        Close();
    }

    private void Close()
    {
        _cts?.Cancel();
        try { _stream?.Dispose(); _tcp?.Dispose(); } catch { }
        _tcp = null; _stream = null; IsReady = false;
    }

    private async Task Open(string host)
    {
        Close();
        var tcp = new TcpClient { NoDelay = true };
        try
        {
            using var t = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            await tcp.ConnectAsync(host, Port, t.Token);
        }
        catch (Exception e)
        {
            tcp.Dispose();
            StatusChanged?.Invoke(Strings.T("Canal de imagen: %@", e.Message));
            ScheduleReconnect();
            return;
        }
        _tcp = tcp; _stream = tcp.GetStream(); _cts = new CancellationTokenSource();
        IsReady = true;
        StatusChanged?.Invoke(Strings.T("Canal de imagen conectado"));
        Ready?.Invoke();
        var ct = _cts.Token;
        _ = Task.Run(() => Heartbeat(ct));
        await ReadLoop(_stream, ct);
    }

    private void ScheduleReconnect()
    {
        if (!_want || _host.Length == 0) return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(3000);
            if (_want && !IsReady) { StatusChanged?.Invoke(Strings.T("Reconectando el canal de imagen…")); await Open(_host); }
        });
    }

    private async Task Heartbeat(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(5000, ct); } catch { return; }
            await SendLine("{\"id\": 2, \"method\": \"test_connection\"}");
        }
    }

    public Task RequestStackedImage() => Request("{\"id\": 23, \"method\": \"get_stacked_img\"}");
    public Task StartPreview() => Request("{\"id\": 21, \"method\": \"begin_streaming\"}");
    public Task StopPreview() => Request("{\"id\": 22, \"method\": \"stop_streaming\"}");

    private Task Request(string line)
    {
        if (_want && !IsReady) ScheduleReconnect();
        return SendLine(line);
    }

    private async Task SendLine(string line)
    {
        try { if (_stream is { } s) await s.WriteAsync(Encoding.UTF8.GetBytes(line + "\r\n")); } catch { }
    }

    private async Task ReadLoop(NetworkStream stream, CancellationToken ct)
    {
        var buf = new MemoryStream();
        var chunk = new byte[4 * 1024 * 1024];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var n = await stream.ReadAsync(chunk, ct);
                if (n == 0) break;
                buf.Write(chunk, 0, n);
                Parse(buf);
            }
        }
        catch { }
        if (ct.IsCancellationRequested) return;
        IsReady = false;
        StatusChanged?.Invoke(Strings.T("Canal de imagen cerrado; reconectando…"));
        ScheduleReconnect();
    }

    private void Parse(MemoryStream buf)
    {
        while (true)
        {
            var data = buf.GetBuffer();
            var len = (int)buf.Length;
            if (len < 80) return;
            var size = (data[6] << 24) | (data[7] << 16) | (data[8] << 8) | data[9];
            int id = data[15], width = (data[16] << 8) | data[17], height = (data[18] << 8) | data[19];
            if (size < 0 || size > 200 * 1024 * 1024) { buf.SetLength(0); return; }
            if (len < 80 + size) return;
            var payload = new byte[size];
            Array.Copy(data, 80, payload, 0, size);
            var rest = len - 80 - size;
            var remaining = new byte[rest];
            Array.Copy(data, 80 + size, remaining, 0, rest);
            buf.SetLength(0); buf.Write(remaining, 0, rest);
            if (size >= 1000) Handle(id, width, height, payload);
        }
    }

    private void Handle(int id, int width, int height, byte[] payload)
    {
        int w = width > 0 ? width : 1080, h = height > 0 ? height : 1920;
        // Las dimensiones vienen de la cabecera del telescopio: se multiplican en 64 bits para que
        // un valor manipulado (p. ej. 65535×65535) no desborde y pase la comprobación de tamaño.
        long px = (long)w * h;
        RawFrame? frame = null;
        if (id == 21)
        {
            if (payload.Length == px * 2) frame = new RawFrame(false, w, h, U16(payload), 1);
            else if (payload.Length == px * 6) frame = new RawFrame(false, w, h, U16(payload), 3);
        }
        else if (id == 23)
        {
            var raw = ExtractZip(payload, "raw_data");
            if (raw is null) { StatusChanged?.Invoke(Strings.T("No se pudo descomprimir la imagen apilada")); return; }
            if (raw.Length == px * 6) frame = new RawFrame(true, w, h, U16(raw), 3);
            else if (raw.Length == px * 2) frame = new RawFrame(true, w, h, U16(raw), 1);
            else StatusChanged?.Invoke(Strings.T("Tamaño de imagen inesperado: %@ bytes", raw.Length));
        }
        if (frame is not null) FrameReceived?.Invoke(frame);
    }

    public const long MaxUncompressed = 128L * 1024 * 1024;

    public static byte[]? ExtractZip(byte[] zip, string name)
    {
        try
        {
            using var z = new ZipArchive(new MemoryStream(zip), ZipArchiveMode.Read);
            var e = z.GetEntry(name) ?? z.Entries.FirstOrDefault();
            if (e is null) return null;
            // El tamaño viene del telescopio: se limita para evitar bombas de descompresión.
            if (e.Length > MaxUncompressed) return null;
            using var s = e.Open();
            var ms = new MemoryStream();
            var buf = new byte[81920];
            int n;
            while ((n = s.Read(buf, 0, buf.Length)) > 0)
            {
                if (ms.Length + n > MaxUncompressed) return null;
                ms.Write(buf, 0, n);
            }
            return ms.ToArray();
        }
        catch { return null; }
    }

    private static ushort[] U16(byte[] d)
    {
        var o = new ushort[d.Length / 2];
        Buffer.BlockCopy(d, 0, o, 0, o.Length * 2);   // little-endian, igual que el x86/ARM de Windows
        return o;
    }
}
