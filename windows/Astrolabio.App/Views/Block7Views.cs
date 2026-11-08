using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Astrolabio.Core;
using Astrolabio.Core.Model;
using Astrolabio.Core.Protocol;
using Astrolabio.Core.Services;
using QRCoder;

namespace Astrolabio.App.Views;

// ---------------------------------------------------------------- Control desde el móvil

public static class Companion
{
    /// <summary>Puente real. El servidor llama desde otro hilo: todo se lee en el hilo de la interfaz.</summary>
    public static CompanionBridge Bridge()
    {
        var st = AppState.Instance;
        byte[]? cache = null; var cacheAt = DateTime.MinValue; object? cacheImg = null;
        T OnUi<T>(Func<T> f) => Dispatcher.UIThread.CheckAccess() ? f() : Dispatcher.UIThread.InvokeAsync(f).GetTask().GetAwaiter().GetResult();
        return new CompanionBridge(
            Status: () => OnUi(() =>
            {
                var c = st.Client; var r = st.Runner; var plan = st.Plan.Items;
                var s = new Dictionary<string, object?>
                {
                    ["connected"] = c.IsConnected, ["running"] = r.IsRunning, ["frames"] = c.StackedFrames,
                    ["battery"] = c.Battery, ["target"] = plan.FirstOrDefault(i => i.Status == PlanItem.ItemStatus.Running)?.Name ?? c.ViewTarget ?? "",
                    ["phase"] = r.IsRunning ? r.PhaseLabel : (c.IsConnected ? c.StackState ?? "" : ""),
                    ["messages"] = r.Messages.TakeLast(5).Reverse().ToList(),
                };
                if (c.ChargerStatus is string ch) s["charging"] = ch.Contains("charg", StringComparison.OrdinalIgnoreCase) && !ch.Contains("not", StringComparison.OrdinalIgnoreCase);
                if (c.StackExposureMs is int e) s["exposure"] = e / 1000.0;
                if (plan.Count > 0)
                    s["plan"] = new Dictionary<string, object?>
                    {
                        ["total"] = plan.Count,
                        ["done"] = plan.Count(i => i.Status is PlanItem.ItemStatus.Done or PlanItem.ItemStatus.Skipped or PlanItem.ItemStatus.Failed),
                        ["remainingMin"] = r.IsRunning ? (int)(r.RemainingSeconds / 60) : null,
                    };
                return s;
            }),
            Jpeg: () => OnUi(() =>
            {
                if (st.Live.Image is not { } img) return null;
                if (ReferenceEquals(img, cacheImg) || (DateTime.Now - cacheAt).TotalSeconds < 10) return cache;
                using var ms = new MemoryStream();
                // PNG de Avalonia recodificado a JPEG con SkiaSharp (más ligero para el móvil).
                img.Save(ms);
                ms.Position = 0;
                using var bmp = SkiaSharp.SKBitmap.Decode(ms);
                if (bmp is null) return null;
                var scale = Math.Min(1.0, 1280.0 / Math.Max(bmp.Width, bmp.Height));
                using var small = bmp.Resize(new SkiaSharp.SKImageInfo((int)(bmp.Width * scale), (int)(bmp.Height * scale)), SkiaSharp.SKFilterQuality.High);
                using var data = (small ?? bmp).Encode(SkiaSharp.SKEncodedImageFormat.Jpeg, 70);
                cache = data.ToArray(); cacheAt = DateTime.Now; cacheImg = img;
                return cache;
            }),
            Stop: () => Dispatcher.UIThread.InvokeAsync(async () =>
            {
                if (st.Runner.IsRunning) { st.Runner.Stop(st.Client); return Strings.T("Sesión automática detenida."); }
                if (!st.Client.IsConnected) return Strings.T("El telescopio no está conectado.");
                try { await st.Client.StopStack(); return Strings.T("Apilado detenido."); } catch (Exception e) { return e.Message; }
            }),
            Skip: () => Dispatcher.UIThread.InvokeAsync(() =>
            {
                if (!st.Runner.IsRunning) return Strings.T("No hay ninguna sesión automática en marcha.");
                st.Runner.Skip(st.Client); return Strings.T("Saltando al siguiente objeto…");
            }).GetTask(),
            Park: () => Dispatcher.UIThread.InvokeAsync(async () =>
            {
                if (st.Runner.IsRunning) st.Runner.Stop(st.Client);
                if (!st.Client.IsConnected) return Strings.T("El telescopio no está conectado.");
                try { try { await st.Client.StopStack(); } catch { } await st.Client.Park(); return Strings.T("Aparcando el telescopio."); }
                catch (Exception e) { return e.Message; }
            }),
            Language: () => Strings.Language.ToString());
    }

    public static void Apply(bool on)
    {
        if (on) CompanionServer.Shared.Start(Bridge()); else CompanionServer.Shared.Stop();
    }

    public static Bitmap? Qr(string text)
    {
        using var gen = new QRCodeGenerator();
        using var data = gen.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(8);
        using var ms = new MemoryStream(png);
        return new Bitmap(ms);
    }
}

public sealed class PhoneView : UserControl
{
    private readonly StackPanel _body = new() { Spacing = 14 };
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };

    public PhoneView()
    {
        Content = Ui.Scroll(_body);
        _timer.Tick += (_, _) => { if (CompanionServer.Shared.Pairing is not null) Fill(); };
        _timer.Start();
        DetachedFromVisualTree += (_, _) => _timer.Stop();
        Fill();
    }

    private void Fill()
    {
        var srv = CompanionServer.Shared; var s = AppState.Instance.Settings;
        _body.Children.Clear();
        _body.Children.Add(Ui.Text(Ui.T("Mira cómo va la noche y para, salta o aparca el telescopio desde el móvil, sin instalar nada: basta el navegador. Solo funciona en tu wifi; nada sale a internet."), 13, color: Ui.Secondary, wrap: true));
        var toggle = new CheckBox { Content = Ui.T("Permitir el control desde el móvil"), IsChecked = s.CompanionEnabled };
        toggle.IsCheckedChanged += (_, _) => { s.CompanionEnabled = toggle.IsChecked == true; s.Save(); Companion.Apply(s.CompanionEnabled); Fill(); };
        var server = new List<Control> { toggle };
        if (srv.IsRunning && srv.Url is string url) server.Add(Ui.Row(Ui.T("Dirección:"), url));
        if (srv.Error is string e) server.Add(Ui.Text(e, 12, color: Ui.Warn));
        server.Add(Ui.Caption(Ui.T("Apagado de serie. Al activarlo, Windows puede pedir permiso en el cortafuegos: permite las redes privadas para que el móvil llegue al PC.")));
        _body.Children.Add(Ui.Card(Ui.T("Servidor para el móvil"), server.ToArray()));
        if (srv.IsRunning)
        {
            if (srv.Pairing is { } p && p.Expires > DateTime.UtcNow && srv.PairingUrl is string link)
            {
                var qr = new Border { Background = Brushes.White, Padding = new Thickness(10), CornerRadius = new CornerRadius(10), Child = new Image { Source = Companion.Qr(link), Width = 220, Height = 220 } };
                var info = Ui.V(Ui.Text(Ui.T("1. Escanea el código con la cámara del móvil (conectado a la misma wifi)."), 13, wrap: true),
                    Ui.Text(Ui.T("2. Escribe este código en el móvil:"), 13),
                    Ui.Text($"{p.Code[..3]} {p.Code[3..]}", 40, FontWeight.Bold, Ui.AccentSoft),
                    Ui.Caption(Ui.T("Caduca en %d s. Sirve para un solo móvil.", (int)(p.Expires - DateTime.UtcNow).TotalSeconds)),
                    Ui.Button(Ui.T("Cancelar"), () => { srv.CancelPairing(); Fill(); }));
                info.MaxWidth = 380;
                _body.Children.Add(Ui.Card(Ui.T("Emparejar un móvil"), Ui.H(qr, info)));
            }
            else _body.Children.Add(Ui.Card(Ui.T("Emparejar un móvil"), Ui.Button(Ui.T("Mostrar el código QR"), () => { srv.StartPairing(); Fill(); }, true)));
            var revoke = Ui.Button(Ui.T("Quitar el acceso a todos"), () => { srv.RevokeAll(); Fill(); });
            revoke.IsEnabled = srv.DeviceCount > 0;
            _body.Children.Add(Ui.Card(Ui.T("Móviles emparejados"), Ui.Text(Ui.T("%d móviles con acceso.", srv.DeviceCount)), revoke,
                Ui.Caption(Ui.T("Cada móvil guarda su propia llave. Quitar el acceso las anula todas: habrá que volver a emparejar."))));
        }
        _body.Children.Add(Ui.Card(Ui.T("Qué puede hacer el móvil"), Ui.Text(Ui.T("Ver el estado, el objeto, los fotogramas, la batería, el avance del plan y la imagen apilada (se actualiza cada 15 s). Parar, saltar al siguiente objeto y aparcar, siempre con confirmación. No puede ver ni cambiar los ajustes, la clave ni los archivos."), 12, wrap: true)));
    }
}

// ---------------------------------------------------------------- Empieza aquí, manual y tutorial

public static class Guide
{
    public static readonly HashSet<Section> BeginnerSections =
        [Section.Start, Section.Tonight, Section.Pick, Section.Telescope, Section.Live, Section.Moon, Section.Planets, Section.Album, Section.Weather, Section.Phone, Section.Help, Section.Settings];
}

public sealed class StartView : UserControl
{
    public StartView(MainWindow w)
    {
        var st = AppState.Instance; var s = st.Settings;
        Control Tile(string title, string icon, string text, Section target)
        {
            var b = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, VerticalContentAlignment = VerticalAlignment.Top,
                MinHeight = 170, Width = 260, Padding = new Thickness(22), Margin = new Thickness(0, 0, 18, 18),
                Background = Ui.CardBg, BorderBrush = Ui.CardStroke, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(18),
                Content = new StackPanel { Spacing = 10, Children = { Ui.Text(icon, 34), Ui.Text(title, 20, FontWeight.Bold), Ui.Text(text, 13, color: Ui.Secondary, wrap: true) } },
            };
            b.Click += (_, _) => w.Navigate(target);
            return b;
        }
        var tiles = new WrapPanel
        {
            Children =
            {
                Tile(st.Client.IsConnected ? Ui.T("Conectado") : Ui.T("Conectar"), "📡", st.Client.IsConnected ? Ui.T("El telescopio está listo.") : Ui.T("Busca el Seestar en tu wifi y conéctate."), Section.Telescope),
                Tile(Ui.T("Qué mirar esta noche"), "🔭", Ui.T("Los mejores objetos para hoy, ordenados."), Section.Tonight),
                Tile(Ui.T("Elige por mí"), "✨", Ui.T("Un objeto y un plan corto, sin pensar."), Section.Pick),
                Tile(Ui.T("Ver en directo"), "📷", Ui.T("Mira cómo crece la imagen apilada."), Section.Live),
            },
        };
        var beginner = new RadioButton { Content = Ui.T("Principiante"), GroupName = "modo", IsChecked = s.BeginnerMode };
        var advanced = new RadioButton { Content = Ui.T("Avanzado"), GroupName = "modo", IsChecked = !s.BeginnerMode };
        beginner.IsCheckedChanged += (_, _) => { if (beginner.IsChecked == true && !s.BeginnerMode) { s.BeginnerMode = true; s.Save(); w.Navigate(Section.Start); } };
        advanced.IsCheckedChanged += (_, _) => { if (advanced.IsChecked == true && s.BeginnerMode) { s.BeginnerMode = false; s.Save(); w.Navigate(Section.Start); } };
        Content = Ui.Scroll(Ui.V(
            Ui.Text(Ui.T("Empieza aquí"), 32, FontWeight.Bold),
            Ui.Text(Ui.T("Cuatro pasos para tu primera foto con el Seestar."), 16, color: Ui.Secondary),
            tiles,
            Ui.H(Ui.Button("🎓 " + Ui.T("Ver el tutorial"), () => w.StartTutorial(), true), Ui.Button("📖 " + Ui.T("Manual"), () => w.OpenHelp(null))),
            Ui.Card(Ui.T("Modo de la app"), Ui.H(beginner, advanced),
                Ui.Caption(s.BeginnerMode ? Ui.T("Ves solo las secciones esenciales.") : Ui.T("Ves todas las secciones.")))));
    }
}

public sealed class HelpView : UserControl
{
    private readonly StackPanel _list = new() { Spacing = 12 };
    private readonly MainWindow _w;
    private readonly string? _highlight;

    public HelpView(MainWindow w, string? highlight)
    {
        _w = w; _highlight = highlight;
        var search = new TextBox { Watermark = Ui.T("Buscar en el manual…"), MaxWidth = 420, HorizontalAlignment = HorizontalAlignment.Left };
        search.TextChanged += (_, _) => Fill(search.Text ?? "");
        var scroll = Ui.Scroll(Ui.V(search, _list));
        Content = scroll;
        Fill("");
        if (highlight is not null)
            Dispatcher.UIThread.Post(() => _list.Children.OfType<Control>().FirstOrDefault(c => c.Tag as string == highlight)?.BringIntoView(), DispatcherPriority.Loaded);
    }

    static string Fold(string s) => new string(s.Normalize(System.Text.NormalizationForm.FormD)
        .Where(c => System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) != System.Globalization.UnicodeCategory.NonSpacingMark).ToArray()).ToLowerInvariant();

    private void Fill(string query)
    {
        _list.Children.Clear();
        var q = Fold(query.Trim());
        var shown = GuideContent.Topics.Where(t => q.Length == 0 || Fold(Ui.T(t.TitleKey) + " " + Ui.T(t.BodyKey)).Contains(q)).ToList();
        if (shown.Count == 0) _list.Children.Add(Ui.Caption(Ui.T("No hay temas con esas palabras.")));
        foreach (var t in shown)
        {
            var items = new List<Control> { Ui.Text(Ui.T(t.BodyKey), 13, wrap: true) };
            if (t.Section is Section s && s != Section.Help)
                items.Add(Ui.Button(Ui.T("Ir a «%@»", Ui.T(MainWindow.SectionKey(s))), () => _w.Navigate(s)));
            var card = Ui.Card(Ui.T(t.TitleKey), items.ToArray());
            card.Tag = t.Id;
            if (t.Id == _highlight) { card.BorderBrush = Ui.Accent; card.BorderThickness = new Thickness(2); }
            _list.Children.Add(card);
        }
    }
}

/// <summary>Tarjeta del tutorial (abajo a la derecha, sobre el contenido).</summary>
public sealed class TutorialCard : Border
{
    public TutorialCard(MainWindow w, int i)
    {
        var steps = GuideContent.Tutorial; var step = steps[Math.Clamp(i, 0, steps.Length - 1)];
        var last = i == steps.Length - 1;
        var head = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        head.Children.Add(Ui.Text(Ui.T(step.TitleKey), 17, FontWeight.Bold));
        var count = Ui.Caption($"{i + 1} / {steps.Length}", false); Grid.SetColumn(count, 1); head.Children.Add(count);
        var prev = Ui.Button(Ui.T("Anterior"), () => w.TutorialGo(i - 1)); prev.IsEnabled = i > 0;
        var buttons = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto") };
        var exit = Ui.Button(Ui.T("Salir"), w.TutorialFinish); buttons.Children.Add(exit);
        Grid.SetColumn(prev, 2); buttons.Children.Add(prev);
        var next = Ui.Button(last ? Ui.T("Terminar") : Ui.T("Siguiente"), () => { if (last) w.TutorialFinish(); else w.TutorialGo(i + 1); }, true);
        next.Margin = new Thickness(8, 0, 0, 0); Grid.SetColumn(next, 3); buttons.Children.Add(next);
        Child = new StackPanel
        {
            Spacing = 10,
            Children = { head, Ui.Text(Ui.T(step.TextKey), 13, wrap: true), new ProgressBar { Minimum = 0, Maximum = steps.Length, Value = i + 1, Height = 6 }, buttons },
        };
        Width = 500; Padding = new Thickness(20); Margin = new Thickness(24);
        HorizontalAlignment = HorizontalAlignment.Right; VerticalAlignment = VerticalAlignment.Bottom;
        Background = Ui.Navy; BorderBrush = Ui.Accent; BorderThickness = new Thickness(1.5); CornerRadius = new CornerRadius(18);
        BoxShadow = new BoxShadows(new BoxShadow { Blur = 20, Color = Color.FromArgb(128, 0, 0, 0) });
    }
}
