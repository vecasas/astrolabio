using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using Astrolabio.Core;
using Astrolabio.Core.Imaging;
using Astrolabio.Core.Protocol;

namespace Astrolabio.App;

/// <summary>Vista en directo: recibe fotogramas del canal 4800, los procesa en segundo plano y publica la imagen.</summary>
public sealed class LiveModel : Observable
{
    private readonly ImageStream _stream = new();
    private readonly SeestarClient _client;
    private LinearImage? _linear;
    private DateTime _lastRequest = DateTime.MinValue;
    private int _gen;

    private WriteableBitmap? _image; public WriteableBitmap? Image { get => _image; private set => Set(ref _image, value); }
    private string _info = Strings.T("Sin imagen"); public string Info { get => _info; private set => Set(ref _info, value); }
    private string _status = ""; public string StreamStatus { get => _status; private set => Set(ref _status, value); }
    private bool _busy; public bool IsProcessing { get => _busy; private set => Set(ref _busy, value); }
    private ProcessingOptions _opts = new();
    public ProcessingOptions Options { get => _opts; set { if (Set(ref _opts, value)) Rerender(); } }
    public bool AutoRefresh { get; set; } = true;
    private Core.Model.StarMetrics.Result? _metrics; public Core.Model.StarMetrics.Result? LastStarMetrics { get => _metrics; private set => Set(ref _metrics, value); }
    public event Action<Core.Model.StarMetrics.Result>? StarMetricsMeasured;
    public bool IsPreviewing { get; private set; }

    public LiveModel(SeestarClient client)
    {
        _client = client;
        _stream.FrameReceived += f => Dispatcher.UIThread.Post(() => Handle(f));
        _stream.StatusChanged += s => Dispatcher.UIThread.Post(() => StreamStatus = s);
        _stream.Ready += () => Dispatcher.UIThread.Post(() => { if (IsPreviewing) _ = _stream.StartPreview(); if (AutoRefresh) RequestStacked(); });
        client.EventReceived += e =>
        {
            if (AutoRefresh && e.Name == "Stack" && (DateTime.Now - _lastRequest).TotalSeconds > 8) RequestStacked();
        };
        _ = Task.Run(async () =>
        {
            while (true)
            {
                await Task.Delay(20_000);
                if (AutoRefresh && _client.IsConnected && (DateTime.Now - _lastRequest).TotalSeconds > 20) RequestStacked();
            }
        });
    }

    public void Connect(string host) => _stream.Connect(host);
    public void Disconnect() { IsPreviewing = false; _stream.Disconnect(); }
    public void RequestStacked() { _lastRequest = DateTime.Now; _ = _stream.RequestStackedImage(); }
    public void StartPreview() { IsPreviewing = true; _ = _stream.StartPreview(); }
    public void StopPreview() { IsPreviewing = false; _ = _stream.StopPreview(); }

    private void Handle(RawFrame f)
    {
        Info = $"{(f.Stacked ? Strings.T("Apilado") : Strings.T("Vista previa"))} · {f.Width}×{f.Height} · {f.Received:T}";
        var gen = ++_gen; var o = Options;
        IsProcessing = true;
        Task.Run(() =>
        {
            var lin = ImageProcessing.Linear(f);
            var r = ImageProcessing.Render(lin, o);
            var m = f.Stacked ? Core.Model.StarMetrics.Measure(Core.Model.StarMetrics.Luminance(lin), lin.Width, lin.Height) : null;
            Dispatcher.UIThread.Post(() =>
            {
                _linear = lin;
                if (m is not null) { LastStarMetrics = m; StarMetricsMeasured?.Invoke(m); }
                if (gen == _gen) { Image = ToBitmap(r); IsProcessing = false; }
            });
        });
    }

    private void Rerender()
    {
        if (_linear is not { } lin) return;
        var gen = ++_gen; var o = Options;
        IsProcessing = true;
        Task.Run(() =>
        {
            var r = ImageProcessing.Render(lin, o);
            Dispatcher.UIThread.Post(() => { if (gen == _gen) { Image = ToBitmap(r); IsProcessing = false; } });
        });
    }

    public static WriteableBitmap ToBitmap(RenderedImage r)
    {
        var wb = new WriteableBitmap(new PixelSize(r.Width, r.Height), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Opaque);
        using var fb = wb.Lock();
        for (var y = 0; y < r.Height; y++) Marshal.Copy(r.Bgra, y * r.Width * 4, fb.Address + y * fb.RowBytes, r.Width * 4);
        return wb;
    }

    /// <summary>Guarda la imagen procesada (PNG) y los datos lineales (FITS).</summary>
    public List<string> Save(string folder, string name)
    {
        var stamp = DateTime.Now.ToString("yyyy-MM-ddTHH-mm-ss");
        var safe = string.IsNullOrWhiteSpace(name) ? "Seestar" : name.Replace('/', '-');
        var saved = new List<string>();
        if (Image is { } img) { var p = Path.Combine(folder, $"{safe}_{stamp}.png"); img.Save(p); saved.Add(p); }
        if (_linear is { } lin) { var p = Path.Combine(folder, $"{safe}_{stamp}.fits"); ImageProcessing.SaveFits(lin, p, safe); saved.Add(p); }
        return saved;
    }
}
