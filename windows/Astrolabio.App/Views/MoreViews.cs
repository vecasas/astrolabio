using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Imaging;
using Astrolabio.Core.Model;
using Astrolabio.Core.Protocol;
using Astrolabio.Core.Services;

namespace Astrolabio.App.Views;

/// <summary>Apilador planetario (vídeos SER; los MP4 aún no se leen en Windows).</summary>
public sealed class StackerView : UserControl
{
    private StackResult? _result;
    private PlanetaryStacker.Finish _finish = new();
    private string? _file;

    public StackerView()
    {
        var st = AppState.Instance;
        var best = new Image { Width = 360, Height = 360 }; var stacked = new Image { Width = 360, Height = 360 };
        var info = Ui.Caption(""); var progress = new ProgressBar { Minimum = 0, Maximum = 1, Width = 300, IsVisible = false }; var msg = Ui.Caption("");
        var keep = new Slider { Minimum = 5, Maximum = 100, Value = 25, Width = 200 };
        var refine = new CheckBox { Content = Ui.T("Alineación fina"), IsChecked = true };
        void Render() { if (_result is { } r) stacked.Source = LiveModel.ToBitmap(PlanetaryStacker.FinishImage(r.Stacked, _finish)); }
        Slider Fin(double min, double max, double v, Func<double, PlanetaryStacker.Finish> make)
        {
            var sl = new Slider { Minimum = min, Maximum = max, Value = v, Width = 200 };
            sl.PropertyChanged += (_, e) => { if (e.Property == Slider.ValueProperty) { _finish = make(sl.Value); Render(); } };
            return sl;
        }
        var choose = Ui.Button(Ui.T("Elegir vídeo…"), async () =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = false, FileTypeFilter = [new FilePickerFileType("SER") { Patterns = ["*.ser"] }] });
            if (files.FirstOrDefault()?.TryGetLocalPath() is not string path) return;
            _file = path;
            try { var src = new SerFrameSource(path); info.Text = Ui.T("%@×%@ · unos %@ fotogramas", src.Width, src.Height, src.EstimatedFrames); }
            catch (Exception e) { info.Text = e.Message; }
        }, true);
        var run = Ui.Button(Ui.T("Apilar"), async () =>
        {
            if (_file is null) return;
            progress.IsVisible = true; msg.Text = Ui.T("Abriendo…");
            var keepPct = keep.Value; var fine = refine.IsChecked == true; var path = _file;
            try
            {
                _result = await Task.Run(() => PlanetaryStacker.Stack(new SerFrameSource(path), keepPct, fine,
                    (t, p) => Avalonia.Threading.Dispatcher.UIThread.Post(() => { msg.Text = t; progress.Value = p; })));
                best.Source = LiveModel.ToBitmap(PlanetaryStacker.FinishImage(_result.BestFrame, new PlanetaryStacker.Finish(0, 0)));
                Render();
                msg.Text = Ui.T("Apilados %@ de %@ fotogramas", _result.Used, _result.Analyzed);
            }
            catch (Exception e) { msg.Text = e.Message; }
            progress.IsVisible = false;
        });
        var save = Ui.Button(Ui.T("PNG"), () =>
        {
            if (stacked.Source is not Bitmap b || _file is null) return;
            var dir = Path.Combine(st.Settings.SaveFolderPath, "Planetario"); Directory.CreateDirectory(dir);
            var p = Path.Combine(dir, $"{Path.GetFileNameWithoutExtension(_file)}_apilado_{_result?.Used}.png");
            b.Save(p); msg.Text = Ui.T("Guardado en %@", p);
        });
        Content = Ui.Scroll(Ui.V(
            Ui.Card(Ui.T("Vídeo"), Ui.Caption(Ui.T("MP4 o MOV (por ejemplo, grabado con el Seestar en modo planeta) o SER de una cámara planetaria.") + " (Windows: SER)"), Ui.H(choose, info)),
            Ui.Card(Ui.T("Apilado"), Ui.Row(Ui.T("Usar el %@ %% más nítido", "…"), keep), refine, Ui.H(run, progress), msg),
            Ui.H(Ui.Card(Ui.T("Mejor fotograma"), best), Ui.Card(Ui.T("Apilado y procesado"), stacked)),
            Ui.Card(Ui.T("Procesado"),
                Ui.Row(Ui.T("Detalle fino"), Fin(0, 4, 1.2, v => _finish with { Fine = v })),
                Ui.Row(Ui.T("Detalle medio"), Fin(0, 3, 0.6, v => _finish with { Medium = v })),
                Ui.Row(Ui.T("Gamma"), Fin(0.5, 2.5, 1, v => _finish with { Gamma = v })), save,
                Ui.Caption(Ui.T("Se guarda en la carpeta de imágenes, dentro de «Planetario».")))));
    }
}

/// <summary>Mosaicos: paneles del Seestar sobre una foto real de la zona.</summary>
public sealed class MosaicView : UserControl
{
    public MosaicView()
    {
        var st = AppState.Instance; var s = st.Settings;
        double ra = 20.988, dec = 44.52, size = 120; string name = "NGC 7000";
        var query = new TextBox { Text = name, Width = 200 };
        var cols = new NumericUpDown { Value = 2, Minimum = 1, Maximum = 3, Width = 120 };
        var rows = new NumericUpDown { Value = 2, Minimum = 1, Maximum = 3, Width = 120 };
        var overlap = new NumericUpDown { Value = 15, Minimum = 5, Maximum = 40, Increment = 5, Width = 120 };
        var minutes = new NumericUpDown { Value = 120, Minimum = 20, Maximum = 600, Increment = 10, Width = 120 };
        var lp = new CheckBox { Content = Ui.T("Filtro antipolución (LP)"), IsChecked = true };
        var preview = new ContentControl(); var msg = Ui.Caption("");
        void Draw()
        {
            int c = (int)(cols.Value ?? 1), r = (int)(rows.Value ?? 1); var ov = (double)(overlap.Value ?? 15);
            double stepW = s.FovWidthDeg * (1 - ov / 100), stepH = s.FovHeightDeg * (1 - ov / 100);
            var span = Math.Min(6, Math.Max(Math.Max(stepW * (c - 1) + s.FovWidthDeg, stepH * (r - 1) + s.FovHeightDeg), size / 60) * 1.15);
            const double px = 520; var scale = px / span;
            var canvas = new Canvas { Width = px, Height = px };
            canvas.Children.Add(new SkyImage(ra, dec, 0, span, span, px));
            for (var row = 0; row < r; row++) for (var col = 0; col < c; col++)
            {
                var x = -(col - (c - 1) / 2.0) * stepW; var y = (row - (r - 1) / 2.0) * stepH;
                var rect = new Border { Width = s.FovWidthDeg * scale, Height = s.FovHeightDeg * scale, BorderBrush = Brushes.Yellow, BorderThickness = new Thickness(1.5),
                    Child = new TextBlock { Text = $"{col + 1}{row + 1}", Foreground = Brushes.Yellow, FontWeight = FontWeight.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
                Canvas.SetLeft(rect, px / 2 + (x - s.FovWidthDeg / 2) * scale); Canvas.SetTop(rect, px / 2 - (y + s.FovHeightDeg / 2) * scale);
                canvas.Children.Add(rect);
            }
            var circle = new Avalonia.Controls.Shapes.Ellipse { Width = size / 60 * scale, Height = size / 60 * scale, Stroke = Ui.AccentSoft, StrokeThickness = 1.2, StrokeDashArray = [6, 4] };
            Canvas.SetLeft(circle, px / 2 - circle.Width / 2); Canvas.SetTop(circle, px / 2 - circle.Height / 2);
            canvas.Children.Add(circle);
            preview.Content = canvas;
        }
        foreach (var n in new[] { cols, rows, overlap }) n.ValueChanged += (_, _) => Draw();
        async void Lookup()
        {
            var q = query.Text ?? "";
            if (Catalog.Find(q) is { } o) { name = o.Id; ra = o.RaHours; dec = o.DecDeg; size = o.SizeArcmin; lp.IsChecked = o.Kind.WantsLP(); msg.Text = o.DisplayName; Draw(); return; }
            msg.Text = Ui.T("Buscando en SIMBAD…");
            if (await NameResolver.Resolve(q) is { } r) { name = q; ra = r.Ra; dec = r.Dec; msg.Text = Ui.T("Encontrado en SIMBAD (indica el tamaño a mano si hace falta)."); Draw(); }
            else msg.Text = Ui.T("No se encontró %@.", q);
        }
        var form = Ui.Card(Ui.T("Mosaico"), Ui.H(query, Ui.Button(Ui.T("Buscar"), Lookup)), msg,
            Ui.Row(Ui.T("Columnas: %@", ""), cols), Ui.Row(Ui.T("Filas: %@", ""), rows), Ui.Row(Ui.T("Solape: %@ %%", ""), overlap), Ui.Row(Ui.T("Tiempo total: %@ min", ""), minutes), lp,
            Ui.Button(Ui.T("Ajustar al tamaño del objeto"), () => { var f = Planner.FrameFitFor(size, s.Fov); cols.Value = f.Columns; rows.Value = f.Rows; }),
            Ui.Button(Ui.T("Añadir al plan"), () =>
            {
                st.Plan.Items.Add(new PlanItem { Name = name, RaHours = ra, DecDeg = dec, Minutes = (double)(minutes.Value ?? 120), MosaicColumns = (int)(cols.Value ?? 1), MosaicRows = (int)(rows.Value ?? 1), OverlapPercent = (double)(overlap.Value ?? 15), LpFilter = lp.IsChecked == true });
                st.Plan.Save(); msg.Text = Ui.T("Añadido al plan. Ve a «Sesión automática» para ejecutarlo.");
            }, true));
        form.Width = 360;
        Content = Ui.Scroll(Ui.H(form, Ui.V(Ui.Text(Ui.T("Vista previa del encuadre"), 14, FontWeight.SemiBold), preview,
            Ui.Caption(Ui.T("Foto real de la zona (DSS2, NASA SkyView) con el norte arriba y el este a la izquierda. Cada rectángulo amarillo es un panel del Seestar, numerado columna-fila; el círculo discontinuo marca el tamaño aproximado del objeto.")))));
        Draw();
    }
}

/// <summary>Álbum: fotos guardadas en el Seestar (portada de cada sesión).</summary>
public sealed class AlbumView : UserControl
{
    public AlbumView()
    {
        var st = AppState.Instance; var c = st.Client;
        var grid = new WrapPanel(); var msg = Ui.Caption("");
        var subs = new CheckBox { Content = Ui.T("Subtomas") };
        async Task Load()
        {
            grid.Children.Clear();
            try
            {
                var reply = await c.Albums();
                var basePath = reply.Str("result.path") ?? "";
                var groups = reply.At("result.list") as System.Text.Json.Nodes.JsonArray ?? [];
                var n = 0;
                foreach (var g in groups.OfType<System.Text.Json.Nodes.JsonObject>())
                foreach (var f in (g["files"] as System.Text.Json.Nodes.JsonArray ?? []).OfType<System.Text.Json.Nodes.JsonObject>())
                {
                    var thn = f.Str("thn"); var name = f.Str("name") ?? thn ?? "";
                    if (thn is null || (!subs.IsChecked.GetValueOrDefault() && name.EndsWith("_sub"))) continue;
                    var url = $"http://{c.Host}/{Uri.EscapeDataString(basePath)}/{string.Join('/', thn.Split('/').Select(Uri.EscapeDataString))}";
                    var full = url.Replace("_thn.jpg", ".jpg");
                    var img = new Image { Width = 180, Height = 130, Stretch = Stretch.UniformToFill };
                    _ = LoadImage(url, img);
                    var tile = new Button { Content = Ui.V(img, Ui.Text(name.Replace("_sub", " · " + Ui.T("Subtomas")).Replace('_', ' '), 12, FontWeight.SemiBold), Ui.Caption($"{f.Int("count") ?? 1} 🖼", false)), Margin = new Thickness(0, 0, 12, 12), Background = Ui.CardBg };
                    tile.Click += (_, _) => { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo { FileName = full, UseShellExecute = true }); } catch { } };
                    grid.Children.Add(tile); n++;
                }
                msg.Text = Ui.T("%@ carpetas en %@ grupos. Haz clic en una foto para verla en grande.", n, groups.Count);
            }
            catch (Exception e) { msg.Text = e.Message; }
        }
        static async Task LoadImage(string url, Image img)
        {
            try { img.Source = new Bitmap(new MemoryStream(await WeatherService.Http.GetByteArrayAsync(url))); } catch { }
        }
        var load = Ui.Button(Ui.T("Cargar"), async () => await Load(), true);
        load.IsEnabled = c.IsConnected;
        Content = Ui.Scroll(Ui.V(Ui.H(load, subs, Ui.Button(Ui.T("Abrir la carpeta"), () => LiveView.OpenFolder(st.Settings.SaveFolderPath))), msg,
            c.IsConnected ? grid : Ui.Caption(Ui.T("Conecta el telescopio para ver su álbum."))));
    }
}

/// <summary>Estadísticas de observación.</summary>
public sealed class StatsView : UserControl
{
    public StatsView()
    {
        var st = AppState.Instance; var h = st.History; var c = st.Client;
        var body = new ContentControl(); var msg = Ui.Caption("");
        string Hours(double m) => m < 60 ? $"{m:F0} min" : $"{m / 60:F1} h";
        void Fill()
        {
            var recs = h.All.OrderByDescending(r => r.Start).ToList();
            if (recs.Count == 0) { body.Content = Ui.Card(Ui.T("Aún no hay sesiones"), Ui.Caption(Ui.T("Astrolabio anota cada sesión de apilado mientras está conectado al Seestar: el objeto, la hora, los fotogramas y el tiempo de integración. Cuando apiles algo, aparecerá aquí. También puedes traer las sesiones anteriores con «Importar del Seestar»."))); return; }
            var longest = recs.MaxBy(r => r.IntegrationMinutes)!;
            var tiles = Ui.Wrap(Ui.Tile(Ui.T("Integración"), Hours(recs.Sum(r => r.IntegrationMinutes))), Ui.Tile(Ui.T("Noches"), recs.Select(r => r.NightDate).Distinct().Count().ToString()),
                Ui.Tile(Ui.T("Sesiones"), recs.Count.ToString()), Ui.Tile(Ui.T("Objetos distintos"), recs.Select(r => r.Target).Distinct().Count().ToString()),
                Ui.Tile(Ui.T("Fotogramas"), recs.Sum(r => r.Frames).ToString("N0", Strings.Culture)), Ui.Tile(Ui.T("Sesión más larga"), Hours(longest.IntegrationMinutes), longest.Target));
            var byObj = recs.GroupBy(r => r.Target).Select(g => (Name: g.Key, Min: g.Sum(r => r.IntegrationMinutes), Count: g.Count(), Last: g.Max(r => r.Start))).OrderByDescending(x => x.Min).ToList();
            var maxMin = Math.Max(1, byObj.First().Min);
            var objRows = Ui.V(byObj.Select(o => (Control)Ui.H(Ui.Text(Catalog.Find(o.Name)?.DisplayName ?? o.Name, 12) is var t && (t.Width = 260) > 0 ? t : t,
                Ui.Text(Hours(o.Min), 12), new Border { Height = 6, Width = Math.Max(2, 160 * o.Min / maxMin), Background = Ui.Accent, CornerRadius = new CornerRadius(3), VerticalAlignment = VerticalAlignment.Center },
                Ui.Caption($"{o.Count} · {o.Last.ToLocalTime():d}", false))).ToArray());
            var sessions = Ui.V(recs.Take(100).Select(r => (Control)Ui.Text($"{r.Start.ToLocalTime().ToString("g", Strings.Culture)} · {r.Target} · {Hours(r.IntegrationMinutes)} · {r.Frames} · {r.ExposureMs / 1000} s", 12)).ToArray());
            body.Content = Ui.V(tiles, Ui.Card(Ui.T("Objetos"), objRows), Ui.Card(Ui.T("Sesiones"), sessions, Ui.Caption(Ui.T("La duración es fotogramas × exposición configurada."))));
        }
        var import = Ui.Button(Ui.T("Importar del Seestar"), async () =>
        {
            try { var n = h.ImportFromAlbum(await c.Albums()); msg.Text = n == 0 ? Ui.T("No hay sesiones nuevas en el álbum.") : Ui.T("Importadas %@ sesiones del álbum del Seestar.", n); Fill(); }
            catch (Exception e) { msg.Text = e.Message; }
        });
        import.IsEnabled = c.IsConnected;
        var export = Ui.Button(Ui.T("Exportar CSV"), async () =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var f = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = "astrolabio_historial.csv" });
            if (f?.TryGetLocalPath() is string p) { File.WriteAllText(p, h.Csv()); msg.Text = Ui.T("Exportado a %@", p); }
        });
        Content = Ui.Scroll(Ui.V(Ui.H(import, export), msg, body));
        Fill();
    }
}

/// <summary>Tiempo: previsión de 48 horas.</summary>
public sealed class WeatherView : UserControl
{
    public WeatherView()
    {
        var st = AppState.Instance;
        var rows = Ui.V(st.Weather.Where(w => w.Time >= DateTime.UtcNow.AddHours(-1)).Take(48).Select(w => (Control)Ui.H(
            Ui.Text(w.Time.ToLocalTime().ToString("ddd HH:mm", Strings.Culture), 12) is var t && (t.Width = 110) > 0 ? t : t,
            new Border { Width = 2 + w.CloudCover * 1.6, Height = 8, Background = Brushes.Gray, CornerRadius = new CornerRadius(3), VerticalAlignment = VerticalAlignment.Center },
            Ui.Caption($"{Ui.T("Nubes")} {w.CloudCover:F0} % · {w.Temperature:F0} °C · {Ui.T("Punto de rocío")} {w.DewPoint:F0} °C · {Ui.T("Humedad")} {w.Humidity:F0} % · {Ui.T("Viento")} {w.Wind:F0} km/h", false))).ToArray());
        Content = Ui.Scroll(Ui.V(Ui.Text(Ui.T("Previsión para %@", st.Settings.SiteName), 16, FontWeight.SemiBold),
            Ui.Wrap(new NightAlertsCard { Width = 420 }, new RadarCard()),
            st.Weather.Count == 0 ? Ui.Caption(Ui.T("Sin previsión del tiempo")) : rows,
            Ui.Caption(Ui.T("Si la temperatura se acerca al punto de rocío, enciende el calentador para que no se empañe."))));
    }
}
