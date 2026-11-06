using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using Astrolabio.App.Views;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;

namespace Astrolabio.App;

public enum Section { Tonight, Pick, SkyChart, Telescope, Live, Moon, Planets, Stacker, Planner, Session, Mosaic, Album, Stats, Weather, Log, Settings }

public sealed class MainWindow : Window
{
    private static readonly (string Group, (Section S, string Key, string Icon)[] Items)[] Groups =
    [
        ("Esta noche", [(Section.Tonight, "Qué mirar", "🔭"), (Section.Pick, "Elige por mí", "✨"), (Section.SkyChart, "Carta estelar", "🗺")]),
        ("Observar", [(Section.Telescope, "Telescopio", "🎯"), (Section.Live, "Vista en directo", "📷")]),
        ("Sistema solar", [(Section.Moon, "Luna", "🌙"), (Section.Planets, "Planetas", "🪐"), (Section.Stacker, "Apilador planetario", "🎞")]),
        ("Planificar", [(Section.Planner, "Planificar la noche", "📋"), (Section.Session, "Sesión automática", "🌌"), (Section.Mosaic, "Mosaicos", "▦")]),
        ("Archivo", [(Section.Album, "Álbum", "🖼"), (Section.Stats, "Estadísticas", "📊")]),
        ("Sistema", [(Section.Weather, "Tiempo", "⛅"), (Section.Log, "Registro", "📜"), (Section.Settings, "Ajustes", "⚙")]),
    ];

    private Section _current = Section.Tonight;
    private readonly ContentControl _content = new();
    private readonly StackPanel _sidebar = new() { Spacing = 2, Margin = new Thickness(10) };
    private readonly TopBar _topBar = new();
    private readonly Image _nightOverlay;

    public MainWindow()
    {
        Title = "Astrolabio";
        Width = 1280; Height = 820; MinWidth = 1000; MinHeight = 680;
        Background = Ui.Deep;
        try { Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://Astrolabio/Assets/Astrolabio.ico"))); } catch { }

        // Modo nocturno: una capa roja que multiplica todo lo que hay debajo.
        var red = new WriteableBitmap(new PixelSize(1, 1), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Opaque);
        using (var fb = red.Lock()) System.Runtime.InteropServices.Marshal.Copy(new byte[] { 10, 20, 255, 255 }, 0, fb.Address, 4);
        _nightOverlay = new Image { Source = red, Stretch = Stretch.Fill, IsHitTestVisible = false };
        RenderOptions.SetBitmapBlendingMode(_nightOverlay, BitmapBlendingMode.Multiply);
        RenderOptions.SetBitmapInterpolationMode(_nightOverlay, BitmapInterpolationMode.None);

        var side = new Border { Width = 230, Background = Ui.Deep, BorderBrush = Ui.CardStroke, BorderThickness = new Thickness(0, 0, 1, 0), Child = new ScrollViewer { Content = _sidebar } };
        var right = new DockPanel { Background = Ui.Background };
        DockPanel.SetDock(_topBar, Dock.Top);
        right.Children.Add(_topBar);
        right.Children.Add(_content);
        var main = new DockPanel();
        DockPanel.SetDock(side, Dock.Left);
        main.Children.Add(side);
        main.Children.Add(right);
        Content = new Panel { Children = { main, _nightOverlay } };

        Strings.LanguageChanged += Rebuild;
        AppState.Instance.Settings.PropertyChanged += (_, _) => UpdateNight();
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.N && e.KeyModifiers.HasFlag(KeyModifiers.Control)) ToggleNight();
        };
        DispatcherTimer.Run(() => { UpdateNight(); return true; }, TimeSpan.FromMinutes(1));
        Rebuild();
        UpdateNight();
    }

    public void ToggleNight()
    {
        var s = AppState.Instance.Settings;
        s.NightMode = !s.NightMode;
        s.Save();
    }

    private void UpdateNight()
    {
        var s = AppState.Instance.Settings;
        var auto = s.NightModeAuto && Astro.SunAltitude(DateTime.UtcNow, s.Latitude, s.Longitude) < -6;
        var on = s.NightMode || auto;
        _nightOverlay.IsVisible = on;
        _nightOverlay.Opacity = 1;
        main_Opacity(on ? s.NightBrightness : 1);
    }

    private void main_Opacity(double v) { if (Content is Panel p && p.Children.Count > 0) p.Children[0].Opacity = Math.Clamp(v, 0.3, 1); }

    public void Navigate(Section s) { _current = s; Rebuild(); }

    private void Rebuild()
    {
        _sidebar.Children.Clear();
        var brand = Ui.H(Ui.Text("✦", 20, color: Ui.AccentSoft), Ui.Text("Astrolabio", 18, FontWeight.Bold));
        brand.Margin = new Thickness(6, 4, 0, 10);
        var info = Ui.Button("ⓘ", () => new AboutWindow().ShowDialog(this));
        info.Background = Brushes.Transparent; info.Padding = new Thickness(4, 0);
        brand.Children.Add(info);
        _sidebar.Children.Add(brand);
        foreach (var (group, items) in Groups)
        {
            var header = Ui.Caption(Ui.T(group).ToUpperInvariant(), false);
            header.Margin = new Thickness(8, 12, 0, 4);
            _sidebar.Children.Add(header);
            foreach (var (sec, key, icon) in items)
            {
                var selected = sec == _current;
                var b = new Button
                {
                    Content = Ui.H(Ui.Text(icon, 14), Ui.Text(Ui.T(key), 13, selected ? FontWeight.SemiBold : FontWeight.Normal)),
                    HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                    Background = selected ? new SolidColorBrush(Color.FromArgb(90, 82, 161, 255)) : Brushes.Transparent,
                    Padding = new Thickness(10, 6),
                };
                b.Click += (_, _) => Navigate(sec);
                _sidebar.Children.Add(b);
            }
        }
        _topBar.Refresh();
        _content.Content = _current switch
        {
            Section.Tonight => new TonightView(this),
            Section.Pick => new PickView(this),
            Section.SkyChart => new SkyChartView(),
            Section.Telescope => new TelescopeView(),
            Section.Live => new LiveView(),
            Section.Moon => new MoonView(),
            Section.Planets => new PlanetsView(),
            Section.Stacker => new StackerView(),
            Section.Planner => new PlannerView(),
            Section.Session => new SessionView(),
            Section.Mosaic => new MosaicView(),
            Section.Album => new AlbumView(),
            Section.Stats => new StatsView(),
            Section.Weather => new WeatherView(),
            Section.Log => new LogView(),
            _ => new SettingsView(),
        };
    }
}

/// <summary>Barra superior: hora, temperatura, nubes, Luna, fase de la noche y conexión.</summary>
public sealed class TopBar : Border
{
    private readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Spacing = 22 };

    public TopBar()
    {
        Background = new SolidColorBrush(Color.FromArgb(140, 5, 13, 31));
        BorderBrush = Ui.CardStroke; BorderThickness = new Thickness(0, 0, 0, 1);
        Padding = new Thickness(18, 10);
        Child = _row;
        DispatcherTimer.Run(() => { Refresh(); return true; }, TimeSpan.FromSeconds(1));
    }

    private static StackPanel Item(string value, string caption) =>
        new() { Spacing = 0, Children = { Ui.Text(value, 14, FontWeight.SemiBold), Ui.Caption(caption, false) } };

    public void Refresh()
    {
        var st = AppState.Instance; var s = st.Settings; var now = DateTime.Now;
        _row.Children.Clear();
        _row.Children.Add(new StackPanel { Children = { Ui.Text(now.ToString("HH:mm:ss"), 24, FontWeight.SemiBold, Ui.AccentSoft), Ui.Caption(now.ToString("dddd, d MMMM", Strings.Culture), false) } });
        var w = st.Weather.Count > 0 ? st.Weather.MinBy(h => Math.Abs((h.Time - DateTime.UtcNow).TotalMinutes)) : null;
        if (w is not null) _row.Children.Add(Item($"{w.Temperature:F0} °C", Ui.T("Exterior")));
        if (st.Client.IsConnected && st.Client.Temperature is double t) _row.Children.Add(Item($"{t:F0} °C", "Seestar"));
        if (w is not null) _row.Children.Add(Item($"{w.CloudCover:F0} %", Ui.T("Nubes")));
        _row.Children.Add(Item($"{Astro.Moon(DateTime.UtcNow).Illumination * 100:F0} %", Ui.T("Luna")));
        var sun = Astro.SunAltitude(DateTime.UtcNow, s.Latitude, s.Longitude);
        var phase = sun switch { < -18 => "Noche cerrada", < -12 => "Crepúsculo astronómico", < -6 => "Crepúsculo náutico", < 0 => "Crepúsculo civil", _ => "De día" };
        _row.Children.Add(Item(Ui.T(phase), Ui.T("Sol a %.0f°", sun)));
        var c = st.Client;
        var conn = Item(c.IsConnected ? (c.DeviceName.Length > 0 ? c.DeviceName : "Seestar") : Ui.T("Sin telescopio"),
            c.IsConnected ? (c.Battery is int b ? Ui.T("Batería %@ %%", b) : c.Host) : c.StatusText);
        conn.Children.Insert(0, new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(5), Background = c.IsConnected ? (c.IsAuthenticated ? Ui.Good : Ui.Warn) : Brushes.Gray, HorizontalAlignment = HorizontalAlignment.Left });
        _row.Children.Add(conn);
    }
}
