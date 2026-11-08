using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Astrolabio.Core;
using Astrolabio.Core.Model;
using Astrolabio.Core.Services;

namespace Astrolabio.App.Views;

/// <summary>Radar de lluvia de las últimas dos horas sobre un mapa oscuro.</summary>
public sealed class RadarCard : UserControl
{
    private const int Grid = 3, TileSize = 160;
    private static readonly Dictionary<string, Bitmap> Cache = new();
    private readonly Canvas _canvas = new() { Width = Grid * TileSize, Height = Grid * TileSize, ClipToBounds = true, Background = new SolidColorBrush(Color.FromRgb(13, 18, 31)) };
    private readonly Image[] _base = new Image[Grid * Grid];
    private readonly Image[] _radar = new Image[Grid * Grid];
    private readonly Slider _slider = new() { Minimum = 0, Maximum = 1, Width = 260 };
    private readonly TextBlock _time = Ui.Caption("", false);
    private readonly Dictionary<string, Bitmap> _frames = new();
    private List<RainRadar.Frame> _list = [];
    private string _host = "";
    private int _zoom = 6;
    private DispatcherTimer? _play;

    public RadarCard()
    {
        for (var k = 0; k < Grid * Grid; k++)
        {
            _base[k] = new Image { Width = TileSize, Height = TileSize };
            _radar[k] = new Image { Width = TileSize, Height = TileSize, Opacity = 0.75 };
            Canvas.SetLeft(_base[k], k % Grid * TileSize); Canvas.SetTop(_base[k], k / Grid * TileSize);
            Canvas.SetLeft(_radar[k], k % Grid * TileSize); Canvas.SetTop(_radar[k], k / Grid * TileSize);
            _canvas.Children.Add(_base[k]); _canvas.Children.Add(_radar[k]);
        }
        _slider.PropertyChanged += (_, e) => { if (e.Property == RangeBase.ValueProperty) ShowFrame((int)Math.Round(_slider.Value)); };
        var play = Ui.Button("▶", () =>
        {
            if (_play is not null) { _play.Stop(); _play = null; return; }
            _play = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
            _play.Tick += (_, _) => { if (_list.Count > 0) _slider.Value = ((int)_slider.Value + 1) % _list.Count; };
            _play.Start();
        });
        var zoom = new ComboBox { ItemsSource = new[] { Ui.T("Cerca"), Ui.T("Región"), Ui.T("Amplio") }, SelectedIndex = 1, Width = 130 };
        zoom.SelectionChanged += (_, _) => { _zoom = 7 - zoom.SelectedIndex; _ = Load(); };
        Content = Ui.Card(Ui.T("Radar de lluvia"), _canvas, Ui.H(play, _slider, _time, zoom),
            Ui.Caption(Ui.T("Radar: RainViewer. Mapa: © OpenStreetMap, © CARTO. El punto azul es tu lugar de observación.")));
        _ = Load();
    }

    private static async Task<Bitmap?> Fetch(string url)
    {
        if (Cache.TryGetValue(url, out var b)) return b;
        try
        {
            var bytes = await WeatherService.Http.GetByteArrayAsync(url);
            if (bytes.Length > 2_000_000) return null;
            var bmp = new Bitmap(new MemoryStream(bytes));
            Cache[url] = bmp;
            return bmp;
        }
        catch { return null; }
    }

    private async Task Load()
    {
        var s = AppState.Instance.Settings;
        var c = RainRadar.Tile(s.Latitude, s.Longitude, _zoom);
        var n = 1 << _zoom;
        _canvas.Children.RemoveAll(_canvas.Children.OfType<Ellipse>().ToList());
        var dot = new Ellipse { Width = 12, Height = 12, Fill = Ui.Accent, Stroke = Brushes.White, StrokeThickness = 2 };
        Canvas.SetLeft(dot, (Grid / 2 + c.Fx) * TileSize - 6); Canvas.SetTop(dot, (Grid / 2 + c.Fy) * TileSize - 6);
        _canvas.Children.Add(dot);
        _frames.Clear();
        try { (_host, _list) = await RainRadar.Frames(); } catch { _list = []; }
        if (_list.Count == 0) { _time.Text = Ui.T("No se pudo cargar el radar (¿sin internet?)."); return; }
        _slider.Maximum = Math.Max(1, _list.Count - 1);
        for (var k = 0; k < Grid * Grid; k++)
        {
            int x = ((c.X + k % Grid - Grid / 2) % n + n) % n, y = c.Y + k / Grid - Grid / 2;
            _base[k].Source = y >= 0 && y < n ? await Fetch(RainRadar.BaseUrl(_zoom, x, y)) : null;
        }
        foreach (var f in Enumerable.Reverse(_list))
            for (var k = 0; k < Grid * Grid; k++)
            {
                int x = ((c.X + k % Grid - Grid / 2) % n + n) % n, y = c.Y + k / Grid - Grid / 2;
                if (y < 0 || y >= n) continue;
                if (await Fetch(RainRadar.RadarUrl(_host, f, _zoom, x, y)) is { } b) _frames[$"{f.Path}|{k}"] = b;
                if (f == _list[^1]) ShowFrame(_list.Count - 1);
            }
        _slider.Value = _list.Count - 1;
    }

    private void ShowFrame(int i)
    {
        if (_list.Count == 0) return;
        var f = _list[Math.Clamp(i, 0, _list.Count - 1)];
        _time.Text = f.Time.ToLocalTime().ToString("t", Strings.Culture);
        for (var k = 0; k < Grid * Grid; k++) _radar[k].Source = _frames.GetValueOrDefault($"{f.Path}|{k}");
    }
}

/// <summary>Avisos oficiales, guardia de tormenta y rocío.</summary>
public sealed class NightAlertsCard : UserControl
{
    public NightAlertsCard()
    {
        var st = AppState.Instance; var g = st.Guard; var s = st.Settings;
        var body = new StackPanel { Spacing = 6 };
        void Fill()
        {
            body.Children.Clear();
            body.Children.Add(g.StormReason is string r ? Ui.Text("⛈ " + r, 13, color: Ui.Bad, wrap: true)
                : Ui.Text("✓ " + Ui.T("Sin tormentas, lluvia ni rachas fuertes previstas en la próxima hora y media."), 12, color: Ui.Good, wrap: true));
            if (g.DewRisk == DewRisk.High) body.Children.Add(Ui.Text("💧 " + Ui.T("Riesgo alto de rocío: enciende el calentador."), 12, color: Ui.Warn, wrap: true));
            else if (g.DewRisk == DewRisk.Possible) body.Children.Add(Ui.Caption(Ui.T("Puede haber rocío más tarde.")));
            if (s.AlertZone.Length == 0) body.Children.Add(Ui.Caption(Ui.T("Elige tu zona de avisos oficiales en Ajustes › Avisos meteorológicos.")));
            else if (g.Warnings.Count == 0) body.Children.Add(Ui.Caption(Ui.T("Sin avisos oficiales para %@.", s.AlertZone)));
            else foreach (var w in g.Warnings)
                body.Children.Add(Ui.V(Ui.Text(w.Headline, 12, FontWeight.SemiBold, w.Level >= 3 ? Ui.Bad : w.Level == 2 ? Ui.Warn : Ui.Secondary, true),
                    Ui.Caption($"{w.Onset.ToLocalTime().ToString("g", Strings.Culture)} – {w.Expires.ToLocalTime().ToString("t", Strings.Culture)}")));
            body.Children.Add(Ui.Caption(Ui.T("Avisos oficiales: MeteoAlarm (AEMET en España).")));
        }
        g.PropertyChanged += (_, _) => Dispatcher.UIThread.Post(Fill);
        Fill();
        Content = Ui.Card(Ui.T("Avisos para esta noche"), body);
    }
}
