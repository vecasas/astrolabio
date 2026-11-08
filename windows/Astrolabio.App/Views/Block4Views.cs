using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Model;

namespace Astrolabio.App.Views;

/// <summary>Línea de tiempo del plan: barras arrastrables sobre la noche y «Simular la noche».</summary>
public sealed class TimelineCard : UserControl
{
    private const double LabelW = 130, RowH = 34, W = 760;
    private readonly Canvas _canvas = new() { Width = LabelW + W, ClipToBounds = true };
    private readonly TextBlock _summary = Ui.Caption("");
    private readonly Action _changed;
    private DateTime? _sim;
    private DispatcherTimer? _timer;

    public TimelineCard(Action changed)
    {
        _changed = changed;
        var sim = Ui.Button(Ui.T("Simular la noche"), Simulate);
        Content = Ui.Card(Ui.T("Línea de tiempo de la noche"), Ui.H(_summary, sim), _canvas,
            Ui.Caption(Ui.T("Arrastra una barra para retrasar su inicio; arrastra su borde derecho para cambiar la duración. Detrás de cada barra, en verde, cuándo se ve el objeto (altura mínima y tu horizonte).")));
        Redraw();
    }

    public void Redraw()
    {
        var st = AppState.Instance; var s = st.Settings;
        var night = Astro.NightFor(DateTime.Now, s.Latitude, s.Longitude);
        _canvas.Children.Clear();
        if (night.Sunset is not DateTime from || night.Sunrise is not DateTime to || to <= from) { _summary.Text = Ui.T("Esta noche no llega a oscurecer del todo."); return; }
        var items = st.Plan.Items.ToList();
        _canvas.Height = 26 + Math.Max(1, items.Count) * RowH;
        var span = (to - from).TotalMinutes;
        double X(DateTime t) => LabelW + (t - from).TotalMinutes / span * W;
        var perMinute = W / span;
        void Rect(double x, double y, double w, double h, IBrush b) { var r = new Rectangle { Width = Math.Max(1, w), Height = h, Fill = b }; Canvas.SetLeft(r, x); Canvas.SetTop(r, y); _canvas.Children.Add(r); }
        void Label(string text, double x, double y, IBrush? c = null) { var t = Ui.Text(text, 10, color: c ?? Ui.Secondary); Canvas.SetLeft(t, x); Canvas.SetTop(t, y); _canvas.Children.Add(t); }
        if (night.DuskStart is DateTime d && night.DawnEnd is DateTime a) Rect(X(d), 0, X(a) - X(d), _canvas.Height, new SolidColorBrush(Colors.Indigo, 0.18));
        var moon = Ephemeris.MoonAltitude(s.Latitude, s.Longitude);
        for (var t = from; t < to; t = t.AddMinutes(15))
            if (moon(t) > 0) Rect(X(t), 14, perMinute * 15, 6, new SolidColorBrush(Colors.Yellow, 0.1 + 0.2 * Astro.Moon(t).Illumination));
        for (var t = new DateTime(from.Year, from.Month, from.Day, from.Hour, 0, 0, DateTimeKind.Utc).AddHours(1); t < to; t = t.AddHours(1))
        {
            Rect(X(t), 0, 1, _canvas.Height, new SolidColorBrush(Colors.White, 0.06));
            Label(t.ToLocalTime().ToString("HH", CultureInfo.InvariantCulture), X(t) + 2, 0);
        }
        Label(Ui.T("☾ Luna"), 4, 10);
        var limit = s.SkyLimit;
        var slots = PlanTimeline.Schedule(items, night, DateTime.UtcNow, limit, s.Latitude, s.Longitude);
        for (var row = 0; row < items.Count; row++)
        {
            var it = items[row];
            var y = 24 + row * RowH;
            Label(it.Name, 4, y + 9, Brushes.White);
            foreach (var (wf, wt) in PlanTimeline.VisibleWindows(it, from, to, limit, s.Latitude, s.Longitude))
                Rect(X(wf), y + 3, X(wt) - X(wf), RowH - 6, new SolidColorBrush(Colors.LimeGreen, 0.16));
            if (slots.FirstOrDefault(x => x.ItemId == it.Id) is not { } slot) continue;
            var current = _sim is DateTime sm && slot.Start <= sm && sm < slot.End;
            var bar = new Border
            {
                Width = Math.Max(12, X(slot.End) - X(slot.Start)), Height = RowH - 10, CornerRadius = new CornerRadius(6),
                Background = slot.HasWarning ? Ui.Warn : Ui.Accent, BorderBrush = Brushes.White, BorderThickness = new Thickness(current ? 2 : 0),
                Child = Ui.Text($"{(slot.HasWarning ? "⚠ " : "")}{slot.Start.ToLocalTime():HH:mm} · {it.Minutes:F0} min", 10, color: Brushes.White),
                Padding = new Thickness(6, 2), Cursor = new Cursor(StandardCursorType.SizeAll),
            };
            ToolTip.SetTip(bar, Warning(slot));
            Canvas.SetLeft(bar, X(slot.Start)); Canvas.SetTop(bar, y + 5);
            _canvas.Children.Add(bar);
            var handle = new Border { Width = 10, Height = RowH - 10, Background = new SolidColorBrush(Colors.White, 0.35), Cursor = new Cursor(StandardCursorType.SizeWestEast) };
            Canvas.SetLeft(handle, X(slot.Start) + bar.Width - 6); Canvas.SetTop(handle, y + 5);
            _canvas.Children.Add(handle);
            Point? press = null;
            bar.PointerPressed += (_, e) => { press = e.GetPosition(_canvas); e.Pointer.Capture(bar); };
            bar.PointerReleased += (_, e) =>
            {
                if (press is not Point p0) return;
                var minutes = Math.Round((e.GetPosition(_canvas).X - p0.X) / perMinute / 5) * 5;
                press = null;
                if (minutes == 0) return;
                var newStart = slot.Start.AddMinutes(minutes);
                it.NotBefore = minutes < 0 && newStart <= slot.Start.AddMinutes(-slot.WaitMinutes) ? null : newStart.ToLocalTime();
                st.Plan.Save(); _changed(); Redraw();
            };
            Point? hpress = null;
            handle.PointerPressed += (_, e) => { hpress = e.GetPosition(_canvas); e.Pointer.Capture(handle); e.Handled = true; };
            handle.PointerReleased += (_, e) =>
            {
                if (hpress is not Point p0) return;
                var minutes = Math.Round((e.GetPosition(_canvas).X - p0.X) / perMinute / 5) * 5;
                hpress = null;
                it.Minutes = Math.Clamp(it.Minutes + minutes, 5, 600);
                st.Plan.Save(); _changed(); Redraw();
            };
        }
        if (_sim is DateTime simT) Rect(X(simT), 0, 2, _canvas.Height, Brushes.White);
        if (slots.Count > 0 && night.DawnEnd is DateTime dawn)
        {
            var free = (dawn - slots[^1].End).TotalMinutes;
            _summary.Text = free >= 0 ? Ui.T("El plan termina a las %@; sobran %@ min de noche.", slots[^1].End.ToLocalTime().ToString("t", Strings.Culture), (int)free)
                                      : Ui.T("El plan termina a las %@, %@ min después del amanecer.", slots[^1].End.ToLocalTime().ToString("t", Strings.Culture), (int)-free);
            if (_sim is DateTime t2)
            {
                var cur = slots.FirstOrDefault(x => x.Start <= t2 && t2 < x.End);
                _summary.Text = $"{t2.ToLocalTime():HH:mm} · {(cur is null ? Ui.T("sin objeto") : items.First(i => i.Id == cur.ItemId).Name)}";
            }
        }
        else _summary.Text = "";
    }

    private static string Warning(PlanSlot s)
    {
        var p = new List<string>();
        if (s.HiddenMinutes >= 10) p.Add(Strings.T("%@ min por debajo de la altura mínima o detrás de tu horizonte", (int)s.HiddenMinutes));
        if (s.AfterDawn) p.Add(Strings.T("termina después del amanecer"));
        if (s.WaitMinutes >= 5) p.Add(Strings.T("espera %@ min antes de empezar", (int)s.WaitMinutes));
        return p.Count == 0 ? "" : string.Join(" · ", p);
    }

    private void Simulate()
    {
        var s = AppState.Instance.Settings;
        var n = Astro.NightFor(DateTime.Now, s.Latitude, s.Longitude);
        if (n.DuskStart is not DateTime d || n.DawnEnd is not DateTime a) return;
        _timer?.Stop();
        var k = 0;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        _timer.Tick += (_, _) =>
        {
            k++;
            if (k > 240) { _timer!.Stop(); _sim = null; Redraw(); return; }
            _sim = d + (a - d) * (k / 240.0);
            Redraw();
        };
        _timer.Start();
    }
}

/// <summary>Editor del horizonte propio: se dibuja con el ratón sobre un panorama de 360°.</summary>
public sealed class HorizonView : UserControl
{
    private const double CW = 900, CH = 260;
    private Horizon _draft;
    private readonly Canvas _canvas = new() { Width = CW, Height = CH, Background = Ui.Navy, ClipToBounds = true };
    private readonly TextBlock _msg = Ui.Caption("");
    private bool _drawing;

    public HorizonView()
    {
        var s = AppState.Instance.Settings;
        _draft = new Horizon(s.Horizon.Altitudes);
        _canvas.PointerPressed += (_, e) => { _drawing = true; Paint(e); e.Pointer.Capture(_canvas); };
        _canvas.PointerMoved += (_, e) => { if (_drawing) Paint(e); };
        _canvas.PointerReleased += (_, _) => _drawing = false;
        var save = Ui.Button(Ui.T("Guardar"), () => { s.Horizon = new Horizon(_draft.Altitudes); s.Save(); _msg.Text = Ui.T("Horizonte guardado para %@.", s.SiteName); }, true);
        var flat = Ui.Button(Ui.T("Horizonte plano"), () => { _draft = Horizon.Flat; Draw(); });
        var import = Ui.Button(Ui.T("Importar…"), async () =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = false });
            if (files.FirstOrDefault()?.TryGetLocalPath() is not string p || new FileInfo(p).Length > 1_000_000 || Horizon.Parse(File.ReadAllText(p)) is not { } h)
            { _msg.Text = Ui.T("No se pudo leer el horizonte de ese archivo."); return; }
            _draft = h; Draw(); _msg.Text = Ui.T("Horizonte importado. Pulsa «Guardar» para usarlo.");
        });
        var export = Ui.Button(Ui.T("Exportar…"), async () =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var f = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = $"horizonte_{SafeName.FileComponent(s.SiteName)}.txt" });
            if (f?.TryGetLocalPath() is string p) { File.WriteAllText(p, $"# Horizonte de {s.SiteName} (acimut altura, grados)\n{_draft.Text()}\n"); _msg.Text = Ui.T("Exportado a %@", p); }
        });
        Content = Ui.Scroll(Ui.V(Ui.Text(Ui.T("Mi horizonte en %@", s.SiteName), 16, FontWeight.SemiBold),
            Ui.Caption(Ui.T("Dibuja con el ratón la altura de lo que tapa el cielo desde tu sitio: árboles, tejados, montes. Los objetos que queden detrás no se sugieren y la sesión automática los espera o los salta.")),
            Ui.Card(Ui.T("Panorama"), _canvas, Ui.Caption(Ui.T("Pulsa y arrastra para dibujar. Mayúsculas + arrastrar borra (pone 0°)."))),
            Ui.H(save, flat, import, export), _msg,
            Ui.Caption(Ui.T("Formato del archivo: una línea por punto con «acimut altura» en grados (0 = norte, 90 = este). Sirve el de otros programas de astronomía con ese formato."))));
        Draw();
    }

    private void Paint(PointerEventArgs e)
    {
        var p = e.GetPosition(_canvas);
        var az = Math.Clamp(p.X / CW * 360, 0, 359.99);
        var alt = e.KeyModifiers.HasFlag(KeyModifiers.Shift) ? 0 : Math.Clamp((CH - p.Y) / CH * Horizon.MaxAltitude, 0, Horizon.MaxAltitude);
        _draft.Set(az, alt);
        Draw();
    }

    private void Draw()
    {
        _canvas.Children.Clear();
        double X(double az) => az / 360 * CW;
        double Y(double alt) => CH - alt / Horizon.MaxAltitude * CH;
        for (var alt = 10.0; alt <= Horizon.MaxAltitude; alt += 10)
        {
            _canvas.Children.Add(new Line { StartPoint = new Point(0, Y(alt)), EndPoint = new Point(CW, Y(alt)), Stroke = new SolidColorBrush(Colors.White, 0.08) });
            var t = Ui.Caption($"{alt:F0}°", false); Canvas.SetLeft(t, 4); Canvas.SetTop(t, Y(alt) - 14); _canvas.Children.Add(t);
        }
        foreach (var (az, name) in new[] { (0.0, "N"), (45.0, "NE"), (90.0, "E"), (135.0, "SE"), (180.0, "S"), (225.0, "SO"), (270.0, "O"), (315.0, "NO") })
        {
            _canvas.Children.Add(new Line { StartPoint = new Point(X(az), 0), EndPoint = new Point(X(az), CH), Stroke = new SolidColorBrush(Colors.White, 0.12) });
            var t = Ui.Text(Ui.T(name), 11, FontWeight.SemiBold, Ui.AccentSoft); Canvas.SetLeft(t, X(az) + 3); Canvas.SetTop(t, 2); _canvas.Children.Add(t);
        }
        var minAlt = AppState.Instance.Settings.MinAltitude;
        _canvas.Children.Add(new Line { StartPoint = new Point(0, Y(minAlt)), EndPoint = new Point(CW, Y(minAlt)), Stroke = Ui.Warn, StrokeDashArray = [4, 3] });
        var pts = new List<Point>();
        for (var az = 0.0; az <= 360; az += 2) pts.Add(new Point(X(az), Y(_draft.AltitudeAt(az))));
        pts.Add(new Point(CW, CH)); pts.Add(new Point(0, CH));
        _canvas.Children.Add(new Polygon { Points = pts, Fill = new SolidColorBrush(Color.FromRgb(15, 41, 26)), Stroke = Brushes.LimeGreen, StrokeThickness = 1.5 });
    }
}

/// <summary>Proyectos de varias noches.</summary>
public sealed class ProjectsPanel : UserControl
{
    private static ProjectStore? _store;
    public static ProjectStore Store => _store ??= new ProjectStore();

    public ProjectsPanel(TextBlock msg)
    {
        var st = AppState.Instance;
        var list = new StackPanel { Spacing = 10 };
        var obj = new TextBox { Width = 240, Watermark = Ui.T("Objeto (p. ej. M31, NGC 7000)") };
        var hours = new NumericUpDown { Value = 10, Minimum = 1, Maximum = 200, Increment = 1, FormatString = "0", Width = 120 };
        void Fill()
        {
            list.Children.Clear();
            if (Store.Projects.Count == 0) list.Children.Add(Ui.Caption(Ui.T("Aún no tienes proyectos.")));
            foreach (var p in Store.Projects.ToList())
            {
                var prog = ProjectStore.Progress(p.ObjectId, st.History.All);
                var o = Catalog.Find(p.ObjectId);
                var bar = new ProgressBar { Minimum = 0, Maximum = 1, Value = prog.Fraction(p.GoalHours), Width = 400 };
                var info = Ui.Text(Ui.T("%@ de %@ h · %@ noches", prog.Hours.ToString("F1", CultureInfo.InvariantCulture), (int)p.GoalHours, prog.Nights), 12);
                var row = Ui.H(bar, info);
                if (prog.Hours >= p.GoalHours) row.Children.Add(Ui.Text("✓ " + Ui.T("Completado"), 12, color: Ui.Good));
                else if (o is not null)
                    row.Children.Add(Ui.Button(Ui.T("Al plan de esta noche"), () =>
                    {
                        st.Plan.Add(o, Math.Max(15, ProjectStore.MinutesForTonight(p.GoalHours, prog.Hours))); st.Plan.Save();
                        msg.Text = Ui.T("%@ añadido al plan.", o.Id);
                    }));
                row.Children.Add(Ui.Button("✕", () => { Store.Projects.Remove(p); Store.Save(); Fill(); }));
                list.Children.Add(Ui.Card(o?.DisplayName ?? p.ObjectId, row));
            }
        }
        var add = Ui.Button(Ui.T("Nuevo proyecto"), () =>
        {
            if (Catalog.Find(obj.Text ?? "") is not { } o) { msg.Text = Ui.T("No encuentro «%@» en el catálogo.", obj.Text ?? ""); return; }
            Store.Projects.Add(new Project { ObjectId = o.Id, GoalHours = (double)(hours.Value ?? 10) }); Store.Save();
            msg.Text = Ui.T("Proyecto creado: %@ h en %@.", (int)(hours.Value ?? 10), o.Id); obj.Text = ""; Fill();
        }, true);
        Content = Ui.V(Ui.H(obj, Ui.Text(Ui.T("Objetivo: %@ h", "").Replace("  ", " "), 12), hours, add),
            Ui.Caption(Ui.T("Un proyecto acumula horas sobre un objeto a lo largo de varias noches. El avance sale de tu historial, incluido lo importado del álbum.")), list);
        Fill();
    }
}

/// <summary>Copia de seguridad y restauración (nunca la clave PEM).</summary>
public sealed class BackupPanel : UserControl
{
    public BackupPanel()
    {
        var st = AppState.Instance;
        var msg = Ui.Caption("");
        var save = Ui.Button(Ui.T("Guardar una copia…"), async () =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var f = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = $"Astrolabio-copia-{DateTime.Now:yyyy-MM-dd}.json" });
            if (f?.TryGetLocalPath() is not string p) return;
            var b = BackupFile.Make(st.Settings, st.Plan.Items, ProjectsPanel.Store.Projects, st.History.Records);
            File.WriteAllText(p, b.Encoded());
            msg.Text = Ui.T("Copia guardada: %@ sesiones, %@ objetos en el plan y %@ proyectos.", b.History.Count, b.Plan.Count, b.Projects.Count);
        });
        var restore = Ui.Button(Ui.T("Restaurar una copia…"), async () =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = false });
            if (files.FirstOrDefault()?.TryGetLocalPath() is not string p) return;
            try
            {
                if (new FileInfo(p).Length > BackupFile.MaxBytes) throw new InvalidDataException(Ui.T("El archivo es demasiado grande para ser una copia de Astrolabio."));
                var b = BackupFile.Decode(File.ReadAllText(p));
                if (!await Ask.YesNo(Ui.T("¿Restaurar esta copia?"), Ui.T("Copia del %@ con %@ sesiones, %@ objetos en el plan y %@ proyectos. Sustituirá lo que tienes ahora. Astrolabio se cerrará para cargarla.",
                        b.Created.ToLocalTime().ToString("g", Strings.Culture), b.History.Count, b.Plan.Count, b.Projects.Count), Ui.T("Restaurar"), Ui.T("Cancelar"))) return;
                b.RestoredSettings(st.Settings).Save();
                st.Plan.Items.Clear(); st.Plan.Items.AddRange(b.Plan); st.Plan.Save();
                ProjectsPanel.Store.Replace(b.Projects);
                st.History.ReplaceAll(b.History);
                (Avalonia.Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown();
            }
            catch (Exception e) { msg.Text = e.Message; }
        });
        Content = Ui.V(Ui.H(save, restore), Ui.Caption(Ui.T("Incluye los ajustes, tus horizontes, el plan, los proyectos y el historial de sesiones. La clave PEM no se copia nunca: tendrás que volver a elegirla.")), msg);
    }
}
