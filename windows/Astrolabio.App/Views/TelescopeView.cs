using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Protocol;
using Astrolabio.Core.Services;

namespace Astrolabio.App.Views;

/// <summary>Telescopio: conexión, estado, GoTo, apilado, mando, enfoque y equipo.</summary>
public sealed class TelescopeView : UserControl
{
    private readonly AppState _st = AppState.Instance;
    private readonly StackPanel _status = new() { Spacing = 4 };
    private readonly TextBlock _conn = Ui.Text("");
    private DeepSkyObject? _catalogObject;

    public TelescopeView()
    {
        var s = _st.Settings; var c = _st.Client;
        // Conexión
        var host = new TextBox { Text = s.TelescopeHost, Width = 180, Watermark = Ui.T("IP del telescopio") };
        var found = Ui.H();
        var auto = new CheckBox { Content = Ui.T("Conectar al abrir"), IsChecked = s.AutoConnect };
        auto.IsCheckedChanged += (_, _) => { s.AutoConnect = auto.IsChecked == true; s.Save(); };
        var connectBtn = Ui.Button(c.IsConnected ? Ui.T("Desconectar") : Ui.T("Conectar"), async () =>
        {
            s.TelescopeHost = host.Text?.Trim() ?? ""; s.Save();
            if (c.IsConnected) _st.Disconnect(); else await _st.Connect();
            Refresh();
        }, true);
        var scan = Ui.Button(Ui.T("Buscar en la red"), async () =>
        {
            var list = await SeestarDiscovery.Scan();
            found.Children.Clear();
            if (list.Count > 0) found.Children.Add(Ui.Caption(Ui.T("Encontrados:"), false));
            foreach (var d in list) found.Children.Add(Ui.Button($"{d.Name} ({d.Ip})", () => host.Text = d.Ip));
            if (list.Count == 1) host.Text = list[0].Ip;
        });
        var connection = Ui.Card(Ui.T("Conexión"), Ui.H(host, connectBtn, scan, auto, _conn), found,
            Ui.Caption(Ui.T("El Seestar debe estar en modo estación (unido a tu wifi). Actívalo una vez desde la app oficial.")));

        // GoTo
        var query = new TextBox { Watermark = Ui.T("M42, NGC 7000, Andrómeda…"), Width = 220 };
        var ra = new TextBox { Watermark = Ui.T("AR (h m s)"), Width = 130 };
        var dec = new TextBox { Watermark = Ui.T("Dec (° ′ ″)"), Width = 130 };
        var name = new TextBox { Watermark = Ui.T("Nombre para las fotos"), Width = 270 };
        var lp = new CheckBox { Content = Ui.T("Filtro antipolución (LP)") };
        var stackAfter = new CheckBox { Content = Ui.T("Empezar a apilar al llegar"), IsChecked = true };
        var msg = Ui.Caption("");
        var imageHost = new ContentControl();
        var adviceHost = new ContentControl();
        void ShowPreview()
        {
            if (Astro.ParseSexagesimal(ra.Text ?? "") is double r && Astro.ParseSexagesimal(dec.Text ?? "") is double d)
            {
                imageHost.Content = new SkyImage(r, d, _catalogObject?.SizeArcmin ?? 0, s.FovWidthDeg, s.FovHeightDeg, 180);
                adviceHost.Content = _catalogObject is { } o ? Ui.H(Advice.Summary(o), Ui.Button(Ui.T("Ir y apilar…"), async () =>
                    await new GotoConfirmWindow(o, m => msg.Text = m).ShowDialog(TopLevel.GetTopLevel(this) as Window ?? throw new InvalidOperationException()))) : null;
            }
        }
        async void Lookup()
        {
            _catalogObject = null;
            var q = query.Text ?? "";
            if (Catalog.Find(q) is { } obj)
            {
                _catalogObject = obj;
                ra.Text = Astro.FormatRA(obj.RaHours); dec.Text = Astro.FormatDec(obj.DecDeg); name.Text = obj.Id;
                lp.IsChecked = obj.Kind.WantsLP(); msg.Text = obj.DisplayName; ShowPreview(); return;
            }
            msg.Text = Ui.T("Buscando en SIMBAD…");
            try
            {
                if (await NameResolver.Resolve(q) is { } res)
                {
                    ra.Text = Astro.FormatRA(res.Ra); dec.Text = Astro.FormatDec(res.Dec); name.Text = q;
                    msg.Text = Ui.T("Encontrado en SIMBAD."); ShowPreview();
                }
                else msg.Text = Ui.T("No se encontró %@.", q);
            }
            catch { msg.Text = Ui.T("Sin conexión a internet para buscar %@.", q); }
        }
        query.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) Lookup(); };
        var gotoBtn = Ui.Button(Ui.T("GoTo"), async () =>
        {
            if (Astro.ParseSexagesimal(ra.Text ?? "") is not double r || Astro.ParseSexagesimal(dec.Text ?? "") is not double d) return;
            var now = Astro.PrecessFromJ2000(r, d, DateTime.UtcNow);
            var n = string.IsNullOrWhiteSpace(name.Text) ? "Objetivo" : name.Text!;
            msg.Text = Ui.T("Apuntando a %@…", n);
            try
            {
                if (await c.GotoAndWait(n, now.Ra, now.Dec, lp.IsChecked == true))
                {
                    msg.Text = Ui.T("Llegó a %@.", n);
                    if (stackAfter.IsChecked == true) { await c.SetTargetName(n); await c.StartStack(); msg.Text = Ui.T("Apilando %@.", n); }
                }
                else msg.Text = Ui.T("El GoTo no terminó bien (¿nubes o poca altura?).");
            }
            catch (Exception e) { msg.Text = e.Message; }
        }, true);
        var syncBtn = Ui.Button(Ui.T("Sincronizar aquí"), async () =>
        {
            if (Astro.ParseSexagesimal(ra.Text ?? "") is double r && Astro.ParseSexagesimal(dec.Text ?? "") is double d)
            { var now = Astro.PrecessFromJ2000(r, d, DateTime.UtcNow); await Ui.Run(Ui.T("Sincronizar"), () => c.Sync(now.Ra, now.Dec)); }
        });
        var gotoCard = Ui.Card(Ui.T("Ir a un objeto"), Ui.H(query, Ui.Button(Ui.T("Buscar"), Lookup)), Ui.H(ra, dec), name, lp, stackAfter,
            imageHost, adviceHost, Ui.H(gotoBtn, Ui.Button(Ui.T("Parar"), async () => await Ui.Run(Ui.T("Parar GoTo"), c.StopGoto)), syncBtn), msg,
            Ui.Caption(Ui.T("Las coordenadas son J2000; se pasan a la fecha antes de enviarlas.")));

        // Apilado
        var exposure = new ComboBox { ItemsSource = new[] { "10 s", "20 s", "30 s" }, SelectedIndex = Math.Clamp((c.StackExposureMs ?? s.ExposureMs) / 10_000 - 1, 0, 2) };
        var gain = new NumericUpDown { Value = c.CurrentGain ?? s.Gain, Minimum = c.GainRange?.Lo ?? 0, Maximum = Math.Max(c.GainRange?.Hi ?? 120, c.CurrentGain ?? s.Gain), Increment = 5, FormatString = "0", Width = 130 };
        var dither = new CheckBox { Content = Ui.T("Dithering"), IsChecked = s.DitherEnabled };
        var afBefore = new CheckBox { Content = Ui.T("Enfoque automático antes de apilar"), IsChecked = s.AutoFocusBeforeStack };
        var stackCard = Ui.Card(Ui.T("Apilado"), Ui.Row(Ui.T("Exposición"), exposure), Ui.Row(Ui.T("Ganancia"), gain), dither, afBefore,
            Ui.H(Ui.Button(Ui.T("Aplicar"), async () =>
            {
                s.ExposureMs = (exposure.SelectedIndex + 1) * 10_000; s.Gain = (int)(gain.Value ?? 80);
                s.DitherEnabled = dither.IsChecked == true; s.AutoFocusBeforeStack = afBefore.IsChecked == true; s.Save();
                await Ui.Run(Ui.T("Ajustes de apilado"), async () =>
                {
                    await c.SetExposure(s.ExposureMs); await c.SetGain(s.Gain);
                    await c.SetDither(s.DitherEnabled, s.DitherPixels, s.DitherInterval); await c.SetAutoFocusBeforeStack(s.AutoFocusBeforeStack);
                });
            }), Ui.Button(Ui.T("Empezar"), async () => await Ui.Run(Ui.T("Empezar a apilar"), () => c.StartStack()), true),
               Ui.Button(Ui.T("Parar"), async () => await Ui.Run(Ui.T("Parar el apilado"), c.StopStack))));

        // Mando y enfoque
        var speed = new Slider { Minimum = 200, Maximum = 5000, Value = 2000, Width = 160 };
        Button Arrow(string t, int angle) => Ui.Button(t, async () => await Ui.Run(Ui.T("Mover"), () => c.Move(angle, (int)speed.Value)));
        var pad = new Grid { ColumnDefinitions = new ColumnDefinitions("44,44,44"), RowDefinitions = new RowDefinitions("40,40,40") };
        void Put(Control x, int r, int col) { Grid.SetRow(x, r); Grid.SetColumn(x, col); pad.Children.Add(x); }
        Put(Arrow("↑", 90), 0, 1); Put(Arrow("←", 180), 1, 0); Put(Ui.Button("■", async () => await Ui.Run(Ui.T("Parar"), c.StopMove)), 1, 1);
        Put(Arrow("→", 0), 1, 2); Put(Arrow("↓", 270), 2, 1);
        var moveCard = Ui.Card(Ui.T("Mover"), pad, Ui.Row(Ui.T("Velocidad"), speed), Ui.Caption(Ui.T("Cada pulsación mueve el telescopio un segundo.")));
        var focusPos = Ui.Caption("");
        Button Nudge(int step) => Ui.Button(step > 0 ? $"+{step}" : $"{step}", async () =>
        {
            try { var cur = await c.FocuserPositionNow() ?? c.FocuserPosition ?? 0; await c.MoveFocuser(cur + step); focusPos.Text = Ui.T("Posición: %@", await c.FocuserPositionNow()); }
            catch (Exception e) { c.AddLog(Ui.T("Enfoque: %@", e.Message), LogLevel.Error); }
        });
        var focusCard = Ui.Card(Ui.T("Enfoque"), Ui.Button(Ui.T("Enfoque automático"), async () =>
        {
            var ok = await c.AutoFocusAndWait(1);
            c.AddLog(ok ? Ui.T("Enfoque automático completado.") : Ui.T("El enfoque automático falló."), ok ? LogLevel.Info : LogLevel.Warning);
        }), Ui.H(Nudge(-100), Nudge(-20), Nudge(20), Nudge(100)), focusPos);

        // Equipo
        var heater = new Slider { Minimum = 0, Maximum = 100, TickFrequency = 10, IsSnapToTickEnabled = true, Value = s.DewHeaterPower, Width = 140 };
        var equipCard = Ui.Card(Ui.T("Equipo"),
            Ui.H(Ui.Button(Ui.T("Abrir brazo"), async () => await Ui.Run(Ui.T("Abrir brazo"), c.OpenArm)), Ui.Button(Ui.T("Aparcar"), async () => await Ui.Run(Ui.T("Aparcar"), c.Park))),
            Ui.Button(Ui.T("Enviar hora y ubicación del Mac").Replace("Mac", "PC"), async () => await Ui.Run(Ui.T("Hora y ubicación"), () => c.SetTimeAndLocation(s.Latitude, s.Longitude))),
            Ui.H(Ui.Text(Ui.T("Calentador"), 12), heater, Ui.Button(Ui.T("Aplicar"), async () => { s.DewHeaterPower = (int)heater.Value; s.Save(); await Ui.Run(Ui.T("Calentador"), () => c.SetDewHeater(s.DewHeaterPower)); })),
            Ui.Button(Ui.T("Tomar oscuros"), async () => await Ui.Run(Ui.T("Oscuros"), c.CreateDarks)),
            Ui.H(Ui.Button(Ui.T("Alineación polar"), async () => await Ui.Run(Ui.T("Alineación polar"), c.StartPolarAlign)), Ui.Button(Ui.T("Parar"), async () => await Ui.Run(Ui.T("Parar alineación polar"), c.StopPolarAlign))),
            Ui.Button(Ui.T("Apagar el telescopio…"), async () =>
            {
                if (await MessageBox.Confirm(Ui.T("¿Apagar el Seestar?"), Ui.T("Tendrás que encenderlo a mano con el botón."), Ui.T("Apagar")))
                    await Ui.Run(Ui.T("Apagar"), c.Shutdown);
            }));

        var statusCard = Ui.Card(Ui.T("Estado"), _status, Ui.Button(Ui.T("Actualizar"), async () => { await c.RefreshDeviceState(); Refresh(); }));
        var cols = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*,*"), ColumnSpacing = 14 };
        void Col(int i, params Control[] cs) { var v = Ui.V(cs); Grid.SetColumn(v, i); cols.Children.Add(v); }
        Col(0, statusCard, equipCard); Col(1, gotoCard, stackCard); Col(2, moveCard, focusCard);
        Content = Ui.Scroll(Ui.V(connection, cols));
        c.PropertyChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(Refresh);
        Refresh();
    }

    private void Refresh()
    {
        var c = _st.Client; var s = _st.Settings;
        _conn.Text = c.StatusText;
        _status.Children.Clear();
        void R(string k, string v) => _status.Children.Add(Ui.Row(k, v));
        R(Ui.T("Nombre"), c.DeviceName.Length > 0 ? c.DeviceName : "—");
        R(Ui.T("Firmware"), c.FirmwareText.Length > 0 ? c.FirmwareText : c.FirmwareVersion > 0 ? c.FirmwareVersion.ToString() : "—");
        R(Ui.T("Autenticado"), c.IsAuthenticated ? Ui.T("Sí") : Ui.T("No"));
        R(Ui.T("Batería"), c.Battery is int b ? $"{b} %" : "—");
        R(Ui.T("Carga"), c.ChargerStatus ?? "—");
        R(Ui.T("Temperatura"), c.Temperature is double t ? $"{t:F1} °C" : "—");
        R(Ui.T("Espacio libre"), c.FreeStorageMB is double f ? Ui.T("%.1f GB", f / 1024) : "—");
        R(Ui.T("Montura"), c.IsEquatorial ? Ui.T("Ecuatorial") : Ui.T("Altacimutal"));
        R(Ui.T("AR"), c.Ra is double ra ? Astro.FormatRA(ra) : "—");
        R(Ui.T("Dec"), c.Dec is double d ? Astro.FormatDec(d) : "—");
        if (c.Ra is double r2 && c.Dec is double d2)
        {
            var aa = Astro.AltAz(r2, d2, DateTime.UtcNow, s.Latitude, s.Longitude);
            R(Ui.T("Altura / acimut"), $"{aa.Alt:F1}° / {aa.Az:F1}°");
        }
        R(Ui.T("Fotogramas apilados"), Ui.T("%@ (descartados %@)", c.StackedFrames, c.DroppedFrames));
        if (c.IsConnected && !c.IsAuthenticated) _status.Children.Add(Ui.Text("⚠ " + (c.AuthMessage.Length > 0 ? c.AuthMessage : Ui.T("Sin autenticar.")), 11, color: Ui.Warn, wrap: true));
    }
}
