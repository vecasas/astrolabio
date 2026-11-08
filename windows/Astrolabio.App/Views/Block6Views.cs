using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Model;

namespace Astrolabio.App.Views;

/// <summary>Guardar, copiar e imprimir imágenes PNG hechas a partir de un control.</summary>
public static class PngExport
{
    public static byte[]? Render(Control c, double width)
    {
        c.Measure(new Size(width, double.PositiveInfinity));
        var h = Math.Max(1, c.DesiredSize.Height);
        c.Arrange(new Rect(0, 0, width, h));
        using var rtb = new RenderTargetBitmap(new PixelSize((int)(width * 2), (int)(h * 2)), new Vector(192, 192));
        rtb.Render(c);
        using var ms = new MemoryStream();
        rtb.Save(ms);
        return ms.Length > 0 ? ms.ToArray() : null;
    }

    public static async Task<string?> Save(Control owner, byte[] png, string name)
    {
        var top = TopLevel.GetTopLevel(owner);
        if (top is null) return null;
        var f = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = name, DefaultExtension = "png" });
        if (f?.TryGetLocalPath() is not string p) return null;
        await File.WriteAllBytesAsync(p, png);
        return p;
    }

    public static async Task<bool> Copy(Control owner, byte[] png)
    {
        if (TopLevel.GetTopLevel(owner)?.Clipboard is not { } cb) return false;
        var data = new DataObject();
        data.Set("PNG", png);
        await cb.SetDataObjectAsync(data);
        return true;
    }

    /// <summary>Imprime con el visor de imágenes de Windows (archivo propio en la carpeta de datos de la app).</summary>
    public static bool Print(byte[] png, string name)
    {
        try
        {
            var path = Path.Combine(AppPaths.Data, SafeName.FileComponent(name) + ".png");
            File.WriteAllBytes(path, png);
            Process.Start(new ProcessStartInfo(path) { Verb = "print", UseShellExecute = true });
            return true;
        }
        catch { return false; }
    }
}

/// <summary>Luna con los nombres de los accidentes (port de MoonAtlasView.swift).</summary>
public static class MoonAtlas
{
    public static Control LabeledMoon(DateTime utc, double size, bool labels = true, int pixels = 500)
    {
        var g = MoonFeatures.Geometry(utc);
        var canvas = new Canvas { Width = size, Height = size };
        canvas.Children.Add(new Image { Source = MoonRenderer.Render(pixels, g), Width = size, Height = size });
        if (!labels) return canvas;
        var r = size / 2;
        foreach (var f in MoonFeatures.DefaultLabels(g))
        {
            var p = MoonFeatures.Project(f, g);
            if (!p.Visible) continue;
            var mare = f.Kind == MoonFeatureKind.Mare;
            double x = r + p.X * (r - 1), y = r - p.Y * (r - 1);
            var t = new TextBlock
            {
                Text = f.Name, FontSize = Math.Max(8, size / (mare ? 30 : 34)), FontWeight = mare ? FontWeight.Normal : FontWeight.SemiBold,
                FontStyle = mare ? FontStyle.Italic : FontStyle.Normal,
                Foreground = mare ? new SolidColorBrush(Color.FromArgb(200, 255, 255, 255)) : Brushes.Gold,
                Effect = new DropShadowEffect { BlurRadius = 3, OffsetX = 0, OffsetY = 0, Color = Colors.Black },
            };
            t.Measure(Size.Infinity);
            Canvas.SetLeft(t, x - t.DesiredSize.Width / 2);
            Canvas.SetTop(t, y - t.DesiredSize.Height / 2 - (mare ? 0 : size / 34));
            canvas.Children.Add(t);
            if (!mare)
            {
                var dot = new Avalonia.Controls.Shapes.Ellipse { Width = 5, Height = 5, Stroke = Brushes.Gold, StrokeThickness = 1 };
                Canvas.SetLeft(dot, x - 2.5); Canvas.SetTop(dot, y - 2.5);
                canvas.Children.Add(dot);
            }
        }
        return canvas;
    }

    /// <summary>Luna rotulada, casilla de nombres y botones de guardar/copiar la imagen.</summary>
    public static Control LabeledMoonPanel(DateTime utc, double size)
    {
        var host = new ContentControl { Content = LabeledMoon(utc, size), Width = size, Height = size };
        var msg = Ui.Caption("");
        var names = new CheckBox { Content = Ui.T("Nombres"), IsChecked = true };
        names.IsCheckedChanged += (_, _) => host.Content = LabeledMoon(utc, size, names.IsChecked == true);
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(host);
        panel.Children.Add(Ui.H(names,
            Ui.Button(Ui.T("Guardar imagen"), async () =>
            {
                if (Snapshot(utc) is not { } png) { msg.Text = Ui.T("No se pudo crear la imagen."); return; }
                if (await PngExport.Save(panel, png, $"Luna_{DateTime.Now:yyyy-MM-dd_HHmm}.png") is string p) msg.Text = Ui.T("Guardada en %@", Path.GetFileName(p));
            }),
            Ui.Button(Ui.T("Copiar"), async () => { if (Snapshot(utc) is { } png && await PngExport.Copy(panel, png)) msg.Text = Ui.T("Copiada al portapapeles"); })));
        panel.Children.Add(msg);
        return panel;
    }

    public static byte[]? Snapshot(DateTime utc)
    {
        var s = AppState.Instance.Settings;
        var m = Astro.Moon(utc); var ph = Astro.MoonPhase(utc);
        var sheet = new Border
        {
            Background = Brushes.Black, Padding = new Thickness(30), Width = 960,
            Child = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    LabeledMoon(utc, 900, true, 900),
                    new TextBlock { Text = $"{utc.ToLocalTime().ToString("f", Strings.Culture)}  ·  {s.Latitude:F2}°, {s.Longitude:F2}°", FontSize = 22, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center },
                    new TextBlock { Text = Ui.T("Norte arriba · %@ · Astrolabio", Ui.T("Iluminada al %.0f %% · %.1f días", m.Illumination * 100, ph.Age)), FontSize = 17, Foreground = Ui.Secondary, HorizontalAlignment = HorizontalAlignment.Center },
                },
            },
        };
        return PngExport.Render(sheet, 960);
    }

    public static Control FeaturesCard(DateTime utc)
    {
        var g = MoonFeatures.Geometry(utc);
        var best = MoonFeatures.BestNow(g);
        var bestRow = new WrapPanel();
        foreach (var f in best) { var p = Ui.Pill(f.Name, Ui.Good); p.Margin = new Thickness(0, 0, 6, 6); bestRow.Children.Add(p); }
        var list = new StackPanel { Spacing = 3 };
        void Fill(MoonFeatureKind? kind)
        {
            list.Children.Clear();
            foreach (var f in MoonFeatures.All.Where(f => kind is null || f.Kind == kind))
            {
                var light = MoonFeatures.Light(f, g);
                var row = new Grid { ColumnDefinitions = new ColumnDefinitions("170,110,130,70,*,Auto") };
                void Add(Control c, int col) { Grid.SetColumn(c, col); row.Children.Add(c); }
                Add(Ui.Text(f.Name, 12), 0);
                Add(Ui.Text(MoonFeature.KindName(f.Kind), 12, color: Ui.Secondary), 1);
                Add(Ui.Text($"{Math.Abs(f.Lat):F1}°{(f.Lat >= 0 ? "N" : "S")} {Math.Abs(f.Lon):F1}°{(f.Lon >= 0 ? "E" : "W")}", 12, color: Ui.Secondary), 2);
                if (f.Kind != MoonFeatureKind.Landing) Add(Ui.Text(Ui.T("%.0f km", f.SizeKm), 12, color: Ui.Secondary), 3);
                Add(Ui.Pill(MoonFeatures.LightName(light), light == MoonLight.Terminator ? Ui.Good : light == MoonLight.Lit ? Ui.Accent : Ui.Secondary), 5);
                list.Children.Add(row);
            }
        }
        var kinds = new ComboBox { ItemsSource = new[] { Ui.T("Todos") }.Concat(Enum.GetValues<MoonFeatureKind>().Select(MoonFeature.KindName)).ToList(), SelectedIndex = 0 };
        kinds.SelectionChanged += (_, _) => Fill(kinds.SelectedIndex <= 0 ? null : (MoonFeatureKind)(kinds.SelectedIndex - 1));
        Fill(null);
        var expander = new Expander { Header = Ui.T("Los %d accidentes de la lista", MoonFeatures.All.Length), Content = Ui.V(kinds, list), HorizontalAlignment = HorizontalAlignment.Stretch };
        return Ui.Card(Ui.T("Qué mirar en la Luna"),
            Ui.Text(Ui.T("Los relieves lucen más junto al terminador, la línea entre el día y la noche lunar: allí el Sol está bajo y las sombras son largas."), 12, color: Ui.Secondary, wrap: true),
            best.Count == 0 ? Ui.Text(Ui.T("Ahora no hay accidentes de la lista junto al terminador (Luna llena o nueva)."), 12) : bestRow,
            Ui.H(Ui.Caption(Ui.T("Libración: %1$+.1f° en longitud, %2$+.1f° en latitud", g.L, g.B), false), Ui.Caption(Ui.T("Colongitud %.1f°", g.Colongitude), false)),
            expander,
            Ui.Caption(Ui.T("El Seestar ve la Luna entera de una vez (su campo mide 44′ × 77′ y la Luna unos 31′), así que no hace falta apuntar a cada cráter: usa el modo Luna y amplía la imagen.")));
    }
}

public static class Compass
{
    public static string Name(double az)
    {
        string[] n = [Ui.T("N"), Ui.T("NE"), Ui.T("E"), Ui.T("SE"), Ui.T("S"), Ui.T("SO"), Ui.T("O"), Ui.T("NO")];
        return n[(int)((Astro.Norm360(az) + 22.5) / 45) % 8];
    }
}

// ---------------------------------------------------------------- Eventos del cielo

public sealed class SkyEventsView : UserControl
{
    private readonly StackPanel _list = new() { Spacing = 14 };
    private List<SkyEvent> _events = [];
    private SkyEventKind? _kind;

    public SkyEventsView()
    {
        var s = AppState.Instance.Settings;
        var filter = new ComboBox { ItemsSource = new[] { Ui.T("Todos") }.Concat(Enum.GetValues<SkyEventKind>().Select(SkyEvent.KindName)).ToList(), SelectedIndex = 0 };
        filter.SelectionChanged += (_, _) => { _kind = filter.SelectedIndex <= 0 ? null : (SkyEventKind)(filter.SelectedIndex - 1); Fill(); };
        _list.Children.Add(Ui.Caption(Ui.T("Calculando…")));
        Content = Ui.Scroll(Ui.V(Ui.Caption(Ui.T("Lo que pasa en el cielo en las próximas seis semanas, calculado para tu lugar.")), filter, _list,
            Ui.Caption(Ui.T("Las horas son aproximadas (unos minutos). Las conjunciones se dan con la separación mínima vista desde el centro de la Tierra."))));
        double lat = s.Latitude, lon = s.Longitude;
        _ = Task.Run(async () =>
        {
            await CometStore.Shared.RefreshIfNeeded();
            var ev = SkyEvents.Upcoming(DateTime.UtcNow, lat, lon, comets: CometStore.Shared.Orbits);
            Dispatcher.UIThread.Post(() => { _events = ev; Fill(); });
        });
    }

    private void Fill()
    {
        _list.Children.Clear();
        var shown = _events.Where(e => _kind is null || e.Kind == _kind).ToList();
        if (shown.Count == 0) { _list.Children.Add(Ui.Card(Ui.T("Sin eventos"), Ui.Text(Ui.T("No hay eventos de este tipo en las próximas seis semanas.")))); return; }
        foreach (var week in shown.GroupBy(e => { var d = e.Date.ToLocalTime().Date; return d.AddDays(-(((int)d.DayOfWeek + 6) % 7)); }).OrderBy(g => g.Key))
            _list.Children.Add(Ui.Card(Ui.T("Semana del %@", week.Key.ToString("d MMMM", Strings.Culture)), week.Select(Row).ToArray()));
    }

    public static Control Row(SkyEvent e)
    {
        var tags = new WrapPanel();
        foreach (var t in e.Tags) { var p = Ui.Pill(SkyEvent.TagName(t), SkyEvent.IsGood(t) ? Ui.Good : Ui.Warn); p.Margin = new Thickness(0, 0, 6, 4); tags.Children.Add(p); }
        var head = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        head.Children.Add(Ui.Text(e.Title, 13, FontWeight.SemiBold));
        var when = Ui.Text(e.Date.ToLocalTime().ToString("ddd d MMM HH:mm", Strings.Culture), 12, color: Ui.Secondary);
        Grid.SetColumn(when, 1); head.Children.Add(when);
        return new StackPanel { Spacing = 3, Margin = new Thickness(0, 2), Children = { head, Ui.Text(e.Detail, 12, color: Ui.Secondary, wrap: true), tags } };
    }
}

// ---------------------------------------------------------------- Satélites

public static class SatellitePasses
{
    public static List<SatellitePass> Passes { get; private set; } = [];
    public static event Action? Updated;
    private static string _key = "";

    public static async Task Update(bool force = false)
    {
        var s = AppState.Instance.Settings; var store = SatelliteStore.Shared;
        await store.RefreshIfNeeded(force);
        var key = $"{s.Latitude},{s.Longitude},{store.Tles.Count},{DateTime.UtcNow:yyyyMMddHH}";
        if (!force && key == _key) return;
        _key = key;
        double lat = s.Latitude, lon = s.Longitude; var tles = store.Tles;
        var res = await Task.Run(() => Satellites.Compute(tles, lat, lon, DateTime.UtcNow));
        Dispatcher.UIThread.Post(() => { Passes = res; Updated?.Invoke(); });
    }
}

public sealed class SatellitesView : UserControl
{
    private readonly StackPanel _passes = new() { Spacing = 3 };
    private readonly TextBlock _info = Ui.Caption("", false);
    private readonly CheckBox _crewed = new() { Content = Ui.T("Solo estaciones tripuladas") };
    private readonly StackPanel _cross = new() { Spacing = 3 };

    public SatellitesView()
    {
        var st = AppState.Instance; var s = st.Settings;
        _crewed.IsCheckedChanged += (_, _) => Fill();
        var targets = st.Forecasts.Take(25).ToList();
        var pick = new ComboBox { ItemsSource = new[] { Ui.T("Elige…") }.Concat(targets.Select(f => f.Object.DisplayName)).ToList(), SelectedIndex = 0, MinWidth = 320 };
        var check = Ui.Button(Ui.T("Comprobar"), async () =>
        {
            if (pick.SelectedIndex <= 0) return;
            var o = targets[pick.SelectedIndex - 1].Object;
            var n = st.Night ?? Astro.NightFor(DateTime.Now, s.Latitude, s.Longitude);
            if (n.Sunset is not DateTime a || n.Sunrise is not DateTime b) return;
            _cross.Children.Clear(); _cross.Children.Add(Ui.Caption(Ui.T("Calculando…")));
            double lat = s.Latitude, lon = s.Longitude; var tles = SatelliteStore.Shared.Tles;
            var from = a.AddMinutes(40) > DateTime.UtcNow ? a.AddMinutes(40) : DateTime.UtcNow; var to = b.AddMinutes(-40);
            var hits = await Task.Run(() => Satellites.Crossings(tles, o.RaHours, o.DecDeg, from, to, lat, lon));
            _cross.Children.Clear();
            if (hits.Count == 0) _cross.Children.Add(Ui.Text(Ui.T("Ningún cruce previsto."), 12, color: Ui.Good));
            foreach (var h in hits) _cross.Children.Add(Ui.Text(Ui.T("%1$@ a las %2$@, a %3$.1f° del centro", h.Name, Ui.Time(h.At), h.Sep), 12));
        });
        var refresh = Ui.Button(Ui.T("Actualizar órbitas"), async () => await SatellitePasses.Update(true));
        Content = Ui.Scroll(Ui.V(
            Ui.H(Ui.Caption(Ui.T("Pasos visibles de la Estación Espacial y de los satélites más brillantes en las próximas cinco noches."), false), refresh),
            Ui.H(_info, _crewed),
            Ui.Card(Ui.T("¿Cruzará algo mi objetivo esta noche?"),
                Ui.Text(Ui.T("Un satélite iluminado deja una raya en la foto. Elige un objeto para ver qué satélites pasarán a menos de 1° mientras esté a oscuras. Durante una sesión automática el aviso es automático."), 12, color: Ui.Secondary, wrap: true),
                Ui.H(pick, check), _cross),
            Ui.Card(Ui.T("Próximos pasos"), _passes),
            Ui.Caption(Ui.T("Solo se muestran pasos con el satélite iluminado por el Sol y tu cielo a oscuras. Precisión: alrededor de un minuto con órbitas de menos de tres días."))));
        SatellitePasses.Updated += Fill;
        DetachedFromVisualTree += (_, _) => SatellitePasses.Updated -= Fill;
        Fill();
        _ = SatellitePasses.Update();
    }

    private void Fill()
    {
        var store = SatelliteStore.Shared;
        _info.Text = store.Updated is DateTime u ? Ui.T("Órbitas de CelesTrak del %@ · %d satélites", u.ToString("d MMM HH:mm", Strings.Culture), store.Tles.Count) : (store.Error ?? "");
        _passes.Children.Clear();
        var list = SatellitePasses.Passes.Where(p => _crewed.IsChecked != true || Satellites.IsCrewed(p.Name)).ToList();
        if (list.Count == 0) _passes.Children.Add(Ui.Caption(store.Tles.Count == 0 ? Ui.T("Descargando las órbitas…") : Ui.T("No hay pasos visibles en estos días.")));
        foreach (var p in list) _passes.Children.Add(Row(p));
    }

    public static Control Row(SatellitePass p)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("24,190,140,90,80,*") };
        void Add(Control c, int col) { Grid.SetColumn(c, col); g.Children.Add(c); }
        var crewed = Satellites.IsCrewed(p.Name);
        Add(Ui.Text(crewed ? "👩‍🚀" : "•", 12, color: crewed ? Ui.Good : Ui.AccentSoft), 0);
        Add(Ui.Text(p.Name, 12), 1);
        Add(Ui.Text(p.Rise.ToLocalTime().ToString("ddd d HH:mm", Strings.Culture), 12), 2);
        Add(Ui.Text(Ui.T("%1$@ → %2$@", Compass.Name(p.RiseAzimuth), Compass.Name(p.SetAzimuth)), 12), 3);
        Add(Ui.Text(Ui.T("máx. %.0f°", p.MaxAltitude), 12), 4);
        Add(Ui.Text(Ui.T("%.0f min", (p.Set - p.Rise).TotalMinutes), 12, color: Ui.Secondary), 5);
        return g;
    }
}

// ---------------------------------------------------------------- Hoja de la noche

public sealed class NightSheetView : UserControl
{
    private readonly ContentControl _host = new();
    private readonly TextBlock _msg = Ui.Caption("");
    private byte[]? _png;

    public NightSheetView()
    {
        var save = Ui.Button(Ui.T("Guardar imagen"), async () =>
        {
            if (_png is null) return;
            if (await PngExport.Save(this, _png, $"Hoja_de_la_noche_{DateTime.Now:yyyy-MM-dd}.png") is string p) _msg.Text = Ui.T("Guardada en %@", Path.GetFileName(p));
        });
        var copy = Ui.Button(Ui.T("Copiar"), async () => { if (_png is not null && await PngExport.Copy(this, _png)) _msg.Text = Ui.T("Copiada al portapapeles"); });
        var print = Ui.Button(Ui.T("Imprimir"), () => { if (_png is not null && !PngExport.Print(_png, "hoja_de_la_noche")) _msg.Text = Ui.T("No se pudo crear la imagen."); });
        Content = Ui.Scroll(Ui.V(Ui.H(Ui.Caption(Ui.T("Un resumen de la noche en una imagen, para guardarla, copiarla o imprimirla."), false), save, copy, print), _msg, _host));
        SatellitePasses.Updated += Redraw;
        AppState.Instance.TonightUpdated += Redraw;
        DetachedFromVisualTree += (_, _) => { SatellitePasses.Updated -= Redraw; AppState.Instance.TonightUpdated -= Redraw; };
        Redraw();
        _ = SatellitePasses.Update();
        _ = Task.Run(async () => { await CometStore.Shared.RefreshIfNeeded(); Dispatcher.UIThread.Post(Redraw); });
    }

    private void Redraw()
    {
        _png = PngExport.Render(NightSheet.Build(DateTime.UtcNow), 1000);
        if (_png is null) return;
        using var ms = new MemoryStream(_png);
        _host.Content = new Image { Source = new Bitmap(ms), MaxWidth = 1000, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left };
    }
}

/// <summary>La hoja de la noche como control (se convierte en PNG para mostrarla, guardarla o imprimirla).</summary>
public static class NightSheet
{
    static readonly IBrush Dim = new SolidColorBrush(Color.FromArgb(180, 255, 255, 255));

    public static string Span(DateTime? rise, DateTime? set) => (rise, set) switch
    {
        (DateTime r, DateTime s) => $"{Ui.Time(r)}–{Ui.Time(s)}",
        (DateTime r, null) => Ui.T("desde %@", Ui.Time(r)),
        (null, DateTime s) => Ui.T("hasta %@", Ui.Time(s)),
        _ => Ui.T("toda la noche"),
    };

    static Border Box(string title, params Control[] children)
    {
        var sp = new StackPanel { Spacing = 6 };
        sp.Children.Add(Ui.Text(title, 15, FontWeight.SemiBold, Ui.AccentSoft));
        foreach (var c in children) sp.Children.Add(c);
        return new Border { Child = sp, Padding = new Thickness(14), CornerRadius = new CornerRadius(12), Background = new SolidColorBrush(Color.FromArgb(16, 255, 255, 255)), BorderBrush = Ui.CardStroke, BorderThickness = new Thickness(1) };
    }

    static Grid Line(string left, string right, IBrush? rightColor = null)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        g.Children.Add(Ui.Text(left, 14, color: Dim));
        var r = Ui.Text(right, 14, color: rightColor ?? Brushes.White); Grid.SetColumn(r, 1); g.Children.Add(r);
        return g;
    }

    static Grid Columns(params Control[] boxes)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions(string.Join(",", boxes.Select(_ => "*"))), Margin = new Thickness(0) };
        for (var i = 0; i < boxes.Length; i++) { boxes[i].Margin = new Thickness(i == 0 ? 0 : 8, 0, i == boxes.Length - 1 ? 0 : 8, 0); Grid.SetColumn(boxes[i], i); g.Children.Add(boxes[i]); }
        return g;
    }

    public static Control Build(DateTime nowUtc)
    {
        var st = AppState.Instance; var s = st.Settings; double lat = s.Latitude, lon = s.Longitude;
        var n = st.Night ?? Astro.NightFor(DateTime.Now, lat, lon);
        var start = n.Sunset ?? nowUtc; var end = n.Sunrise ?? start.AddHours(12);
        var hours = Math.Max(1, (end - start).TotalHours);
        var mid = start + (end - start) / 2;
        var moonRs = Ephemeris.Compute(start.AddHours(-6), hours + 12, 300, 0.125, Ephemeris.MoonAltitude(lat, lon));
        var moon = Astro.Moon(mid);

        var planets = new List<Control>();
        foreach (var name in Astro.PlanetNames)
        {
            var rs = Ephemeris.Compute(start, hours, 600, 0, Ephemeris.PlanetAltitude(name, lat, lon));
            if (rs.NeverUp || rs.MaxAltitude <= 10) continue;
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("80,*,Auto") };
            g.Children.Add(Ui.Text(Ui.T(name), 14, color: Brushes.White));
            var span = Ui.Text(Span(rs.Rise, rs.Set), 14, color: Brushes.White); Grid.SetColumn(span, 1); g.Children.Add(span);
            var alt = Ui.Text($"{rs.MaxAltitude:F0}°", 14, color: Dim); Grid.SetColumn(alt, 2); g.Children.Add(alt);
            planets.Add(g);
        }
        if (planets.Count == 0) planets.Add(Ui.Text(Ui.T("Ninguno alto esta noche."), 14, color: Dim));

        var targets = st.Forecasts.Take(8).Select((f, i) => (Control)Line($"{i + 1}. {f.Object.DisplayName}",
            $"{string.Join("–", new[] { f.WindowStart, f.WindowEnd }.Where(d => d is not null).Select(d => Ui.Time(d)))}   {Ui.T("máx. %.0f°", f.MaxAltitude)}")).ToList();
        if (targets.Count == 0) targets.Add(Ui.Text(Ui.T("Abre «Qué mirar» para calcular la lista."), 14, color: Dim));

        var passes = SatellitePasses.Passes.Where(p => p.Rise >= start && p.Rise <= end).Take(6)
            .Select(p => (Control)Line($"{p.Name}  {Ui.Time(p.Rise)}  {Ui.T("%1$@ → %2$@", Compass.Name(p.RiseAzimuth), Compass.Name(p.SetAzimuth))}", $"{p.MaxAltitude:F0}°")).ToList();
        if (passes.Count == 0) passes.Add(Ui.Text(Ui.T("Sin pasos visibles esta noche."), 14, color: Dim));

        var comets = Comets.Visible(CometStore.Shared.Orbits, n, lat, lon, s.MinAltitude, 11).Take(4)
            .Select(c => (Control)Line(c.Orbit.Name, $"mag {c.Position.Magnitude:F1}")).ToList();
        if (comets.Count == 0) comets.Add(Ui.Text(Ui.T("Ninguno al alcance esta noche."), 14, color: Dim));

        var events = SkyEvents.Upcoming(start, lat, lon, 7).Take(6)
            .Select(e => (Control)Line(e.Title, e.Date.ToLocalTime().ToString("ddd d HH:mm", Strings.Culture))).ToList();
        if (events.Count == 0) events.Add(Ui.Text(Ui.T("Nada destacado."), 14, color: Dim));

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        header.Children.Add(Ui.Text(Ui.T("Hoja de la noche"), 32, FontWeight.Bold, Brushes.White));
        var date = Ui.Text(DateTime.Now.ToString("D", Strings.Culture), 20, color: Brushes.White); date.VerticalAlignment = VerticalAlignment.Bottom;
        Grid.SetColumn(date, 1); header.Children.Add(date);

        var moonBox = Box(Ui.T("Luna"),
            Ui.H(new Image { Source = MoonRenderer.Render(160, MoonFeatures.Geometry(mid)), Width = 64, Height = 64 },
                 new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center, Children = { Ui.Text(Astro.MoonPhase(mid).Name, 16, FontWeight.SemiBold, Brushes.White), Ui.Text(Ui.T("Iluminada al %.0f %%", moon.Illumination * 100), 14, color: Dim) } }),
            Line(Ui.T("Sale"), Ui.Time(moonRs.Rise)), Line(Ui.T("Se pone"), Ui.Time(moonRs.Set)));

        return new Border
        {
            Width = 1000, Padding = new Thickness(30),
            Background = new LinearGradientBrush { StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Color.FromRgb(5, 13, 31), 0), new GradientStop(Color.FromRgb(13, 27, 57), 1) } },
            Child = new StackPanel
            {
                Spacing = 16,
                Children =
                {
                    header,
                    Ui.Text(Ui.T("Lugar: %@", $"{lat:F2}°, {lon:F2}°"), 15, color: Dim),
                    Columns(Box(Ui.T("Oscuridad"), Line(Ui.T("Puesta de sol"), Ui.Time(n.Sunset)), Line(Ui.T("Noche cerrada"), Ui.Time(n.DuskStart)),
                                Line(Ui.T("Fin de la noche"), Ui.Time(n.DawnEnd)), Line(Ui.T("Salida del sol"), Ui.Time(n.Sunrise))),
                            moonBox, Box(Ui.T("Planetas"), planets.ToArray())),
                    Box(Ui.T("Los mejores objetos para el Seestar"), targets.ToArray()),
                    Columns(Box(Ui.T("Estación Espacial y satélites"), passes.ToArray()), Box(Ui.T("Cometas"), comets.ToArray())),
                    Box(Ui.T("Esta semana en el cielo"), events.ToArray()),
                    Ui.Text(Ui.T("Hecho con Astrolabio para el Seestar S50 · horas locales"), 12, color: new SolidColorBrush(Color.FromArgb(115, 255, 255, 255))),
                },
            },
        };
    }
}
