using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Astrolabio.Core;
using Astrolabio.Core.Model;
using Astrolabio.Core.Protocol;

namespace Astrolabio.App.Views;

/// <summary>Datos de «Acerca de» (un único sitio, igual que AppInfo.swift en macOS).</summary>
public static class AppInfo
{
    public const string Version = "1.8.0";
    public const string Build = "1";
    public const string Author = "Víctor Casas";
    public const string Email = "vecasas@gmail.com";
    public const string Repository = "https://github.com/vecasas/astrolabio";
    public static readonly DateTime Created = new(2026, 11, 5);
}

public sealed class AboutWindow : Window
{
    public AboutWindow()
    {
        Title = Ui.T("Acerca de Astrolabio");
        Width = 460; SizeToContent = SizeToContent.Height; Background = Ui.Navy; CanResize = false; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        void Open(string url) { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo { FileName = url, UseShellExecute = true }); } catch { } }
        var mail = Ui.Button(AppInfo.Email, () => Open("mailto:" + AppInfo.Email)); mail.Background = Brushes.Transparent; mail.Foreground = Ui.AccentSoft;
        var repo = Ui.Button("github.com/vecasas/astrolabio", () => Open(AppInfo.Repository)); repo.Background = Brushes.Transparent; repo.Foreground = Ui.AccentSoft;
        Content = new StackPanel
        {
            Margin = new Thickness(28), Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center,
            Children =
            {
                Ui.Text("✦", 48, color: Ui.AccentSoft), Ui.Text("Astrolabio", 30, FontWeight.Bold),
                Ui.Caption(Ui.T("Control del Seestar desde el Mac").Replace("Mac", "PC"), false),
                Ui.Row(Ui.T("Versión"), $"{AppInfo.Version} ({AppInfo.Build}) · Windows"),
                Ui.Row(Ui.T("Autor"), AppInfo.Author),
                Ui.Row(Ui.T("Creada el"), AppInfo.Created.ToString("D", Strings.Culture)),
                Ui.Row(Ui.T("Contacto"), mail), Ui.Row(Ui.T("Código fuente"), repo),
                Ui.Caption(Ui.T("Datos: d3-celestial y catálogo HYG (estrellas), NASA LRO (Luna), DSS2 vía NASA SkyView (fotos), Open-Meteo (tiempo), Wikipedia (descripciones), CDS SIMBAD (búsqueda).")),
                Ui.Caption(Ui.T("Catálogo ampliado: OpenNGC de Mattia Verga (CC BY-SA 4.0). Cometas: Minor Planet Center. Avisos: MeteoAlarm. Radar: RainViewer.")),
                Ui.Caption(Ui.T("Astrolabio es independiente y no está afiliado a ZWO.")),
            },
        };
    }
}

public sealed class SettingsView : UserControl
{
    public SettingsView()
    {
        var st = AppState.Instance; var s = st.Settings;
        TextBox Tb(string v, Action<string> set, double w = 260) { var t = new TextBox { Text = v, Width = w }; t.LostFocus += (_, _) => { set(t.Text ?? ""); s.Save(); }; return t; }
        NumericUpDown Num(double v, double min, double max, double step, Action<double> set, string fmt = "0.####")
        { var n = new NumericUpDown { Value = (decimal)v, Minimum = (decimal)min, Maximum = (decimal)max, Increment = (decimal)step, FormatString = fmt, Width = 160 }; n.ValueChanged += (_, _) => { set((double)(n.Value ?? 0)); s.Save(); }; return n; }
        CheckBox Cb(string t, bool v, Action<bool> set) { var c = new CheckBox { Content = t, IsChecked = v }; c.IsCheckedChanged += (_, _) => { set(c.IsChecked == true); s.Save(); }; return c; }
        Control Labeled(string key, double v, double min, double max, double step, Action<double> set)
        {
            var label = Ui.Text(Ui.T(key, (int)v), 12, color: Ui.Secondary);
            var n = Num(v, min, max, step, x => { set(x); label.Text = Ui.T(key, (int)x); }, "0");
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
            g.Children.Add(label); Grid.SetColumn(n, 1); g.Children.Add(n);
            return g;
        }

        var country = new ComboBox { ItemsSource = MeteoAlarm.Countries, SelectedItem = s.AlertCountry, Width = 220 };
        var zone = new ComboBox { Width = 320 };
        async Task LoadZones()
        {
            var zones = new List<string> { Ui.T("Ninguna") };
            try { zones.AddRange(MeteoAlarm.Areas(await MeteoAlarm.Fetch(s.AlertCountry))); } catch { }
            if (s.AlertZone.Length > 0 && !zones.Contains(s.AlertZone)) zones.Add(s.AlertZone);
            zone.ItemsSource = zones;
            zone.SelectedItem = s.AlertZone.Length == 0 ? zones[0] : s.AlertZone;
        }
        country.SelectionChanged += async (_, _) => { if (country.SelectedItem is string c && c != s.AlertCountry) { s.AlertCountry = c; s.AlertZone = ""; s.Save(); await LoadZones(); } };
        zone.SelectionChanged += (_, _) => { if (zone.SelectedIndex >= 0) { s.AlertZone = zone.SelectedIndex == 0 ? "" : zone.SelectedItem as string ?? ""; s.Save(); } };
        _ = LoadZones();
        var lang = new ComboBox { ItemsSource = Strings.Languages.Select(l => l.Native).ToList(), SelectedIndex = (int)Strings.Language, Width = 200 };
        lang.SelectionChanged += (_, _) => { var l = (AppLanguage)lang.SelectedIndex; s.Language = l.ToString(); s.Save(); Strings.SetLanguage(l); };

        var pem = Tb(s.PemPath, v => s.PemPath = v, 360);
        var pemMsg = Ui.Caption("");
        var choosePem = Ui.Button(Ui.T("Elegir…"), async () =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = false, FileTypeFilter = [new FilePickerFileType("PEM") { Patterns = ["*.pem", "*"] }] });
            if (files.FirstOrDefault()?.TryGetLocalPath() is string path)
            {
                pem.Text = path; s.PemPath = path; s.Save();
                try { using var _ = SeestarSigner.FromFile(path); pemMsg.Text = "✓"; } catch { pemMsg.Text = Ui.T("Ese archivo no parece una clave RSA privada."); }
            }
        });
        var testMsg = Ui.Caption("");
        var topic = Tb(s.NtfyTopic, v => s.NtfyTopic = v.Trim());
        var gen = Ui.Button(Ui.T("Generar uno"), () =>
        {
            const string chars = "abcdefghjkmnpqrstuvwxyz23456789";
            string Block() => new(Enumerable.Range(0, 4).Select(_ => chars[Random.Shared.Next(chars.Length)]).ToArray());
            topic.Text = s.NtfyTopic = $"astrolabio-{Block()}-{Block()}-{Block()}"; s.Save();
        });

        Content = Ui.Scroll(Ui.V(
            Ui.Card(Ui.T("Idioma"), Ui.Row(Ui.T("Idioma de la interfaz"), lang)),
            Ui.Card(Ui.T("Acerca de"), Ui.Row(Ui.T("Versión"), $"{AppInfo.Version} ({AppInfo.Build})"), Ui.Row(Ui.T("Autor"), AppInfo.Author), Ui.Row(Ui.T("Contacto"), AppInfo.Email),
                Ui.Button(Ui.T("Acerca de Astrolabio"), () => new AboutWindow().ShowDialog(TopLevel.GetTopLevel(this) as Window ?? throw new InvalidOperationException()))),
            Ui.Card(Ui.T("Lugar de observación"),
                Ui.Row(Ui.T("Nombre"), Tb(s.SiteName, v => s.SiteName = v)),
                Ui.Row(Ui.T("Latitud (°, norte positivo)"), Num(s.Latitude, -90, 90, 0.0001, v => s.Latitude = v)),
                Ui.Row(Ui.T("Longitud (°, este positivo)"), Num(s.Longitude, -180, 180, 0.0001, v => s.Longitude = v)),
                Ui.Row(Ui.T("Altura mínima: %@°", (int)s.MinAltitude), Num(s.MinAltitude, 10, 60, 5, v => s.MinAltitude = v)),
                Ui.Row(Ui.T("Nubes máximas: %@ %%", (int)s.MaxCloudCover), Num(s.MaxCloudCover, 10, 100, 10, v => s.MaxCloudCover = v))),
            Ui.Card(Ui.T("Telescopio"),
                Ui.Row(Ui.T("IP"), Tb(s.TelescopeHost, v => s.TelescopeHost = v.Trim())),
                Ui.Row(Ui.T("Clave PEM"), Ui.H(pem, choosePem)), pemMsg,
                Ui.Caption(Ui.T("El firmware reciente del Seestar exige que el cliente firme un reto con una clave privada. Indica aquí el archivo .pem que uses con seestar_alp (opción interop_pem).")),
                Ui.Row(Ui.T("Campo de visión (°)"), Ui.H(Num(s.FovWidthDeg, 0.1, 5, 0.01, v => s.FovWidthDeg = v), Ui.Text("×"), Num(s.FovHeightDeg, 0.1, 5, 0.01, v => s.FovHeightDeg = v))),
                Ui.Caption(Ui.T("Seestar S50: 0,73° × 1,29°."))),
            Ui.Card(Ui.T("Seguridad del apuntado"),
                Labeled("No apuntar a menos de %@° del Sol", s.SunSafetyDeg, GotoSafety.SunSeparationFloor, 90, 5, v => s.SunSafetyDeg = v),
                Labeled("No apuntar por debajo de %@° de altura", s.GotoMinAltitude, 0, 45, 5, v => s.GotoMinAltitude = v),
                Ui.Caption(Ui.T("Se aplica a todos los GoTo: telescopio, planes, mosaicos, carta estelar, Luna, planetas y sugerencias. La protección solar no se puede desactivar (mínimo %@°).", (int)GotoSafety.SunSeparationFloor)),
                Cb(Ui.T("Recentrar si el objeto queda descentrado tras el GoTo"), s.RecenterEnabled, v => s.RecenterEnabled = v),
                Labeled("Tolerancia: %@′", s.RecenterToleranceArcmin, 1, 15, 1, v => s.RecenterToleranceArcmin = v)),
            Ui.Card(Ui.T("Enfoque y rocío"),
                Cb(Ui.T("Vigilar la nitidez de las estrellas durante el apilado"), s.FocusWatch, v => s.FocusWatch = v),
                Labeled("Avisar si empeora más de un %@ %%", s.FocusThresholdPercent, 10, 100, 5, v => s.FocusThresholdPercent = v),
                Cb(Ui.T("Volver a enfocar automáticamente en la sesión automática"), s.AutoRefocus, v => s.AutoRefocus = v),
                Cb(Ui.T("Encender el calentador si hay riesgo alto de rocío"), s.AutoDewHeater, v => s.AutoDewHeater = v),
                Ui.Caption(Ui.T("Astrolabio mide el tamaño de las estrellas en cada apilado. Si crecen, suele ser el enfoque (cambio de temperatura) o rocío en la lente."))),
            Ui.Card(Ui.T("Avisos meteorológicos"),
                Cb(Ui.T("Recoger el telescopio si hay tormenta, lluvia o viento fuerte"), s.StormGuard, v => s.StormGuard = v),
                Ui.Row(Ui.T("País"), country),
                Ui.Row(Ui.T("Zona de avisos"), zone),
                Ui.Caption(Ui.T("La lista muestra las zonas con avisos en los últimos días; si la tuya no aparece, vuelve a mirar otro día.")),
                Ui.Caption(Ui.T("Con la guardia activada, la sesión automática aparca el telescopio y espera 30 minutos sin avisos antes de seguir."))),
            Ui.Card(Ui.T("Copia de seguridad"), new BackupPanel()),
            Ui.Card(Ui.T("Avisos al móvil"),
                Cb(Ui.T("Avisar de batería baja, poca memoria o telescopio sin respuesta"), s.HealthAlerts, v => s.HealthAlerts = v),
                Ui.Text(Ui.T("Astrolabio puede avisarte en el móvil de lo que pasa durante la noche, aunque estés lejos del Mac. **No hace falta número de teléfono ni crear una cuenta**: se usa ntfy, una app gratuita para iPhone y Android.").Replace("**", "").Replace("Mac", "PC"), 12, wrap: true),
                Ui.Caption(Ui.T("Cómo funciona: eliges un «tema», que es como el nombre de un canal privado. Astrolabio publica los avisos en ese tema y la app ntfy del móvil, suscrita a él, te los muestra como notificaciones.")),
                Ui.Text(Ui.T("Qué se avisa"), 13, FontWeight.SemiBold),
                Ui.Caption("• " + Ui.T("El plan de la sesión automática ha terminado.") + "\n• " + Ui.T("La sesión se ha puesto en pausa porque se prevén nubes.") + "\n• " + Ui.T("Un objeto del plan no se pudo completar (GoTo o enfoque fallidos).") + "\n• " + Ui.T("Un apilado ha terminado al cumplir la duración elegida en «Antes de ir».")),
                Ui.Text(Ui.T("1. Instala **ntfy** en el móvil (App Store o Google Play).").Replace("**", ""), 12, wrap: true),
                Ui.Text(Ui.T("2. Elige un tema difícil de adivinar (quien lo conozca podría leer los avisos):"), 12, wrap: true),
                Ui.H(topic, gen),
                Ui.Text(Ui.T("3. En la app ntfy pulsa «+» (suscribirse a un tema) y escribe ese mismo tema, o escanea este código con la cámara del móvil:").Split(',')[0] + ".", 12, wrap: true),
                Ui.Button(Ui.T("Enviar un aviso de prueba"), () => { s.Notify("Astrolabio", Ui.T("Prueba de aviso desde el Mac. ¡Funciona!").Replace("Mac", "PC")); testMsg.Text = Ui.T("Enviado. Debería llegarte al móvil en unos segundos."); }, true), testMsg,
                Ui.Row(Ui.T("Servidor ntfy"), Tb(s.NtfyServer, v => s.NtfyServer = v))),
            Ui.Card(Ui.T("Modo nocturno"),
                Cb(Ui.T("Activado"), s.NightMode, v => s.NightMode = v),
                Cb(Ui.T("Activarlo solo al anochecer (Sol por debajo de −6°)"), s.NightModeAuto, v => s.NightModeAuto = v),
                Ui.Row(Ui.T("Brillo"), Num(s.NightBrightness, 0.3, 1, 0.05, v => s.NightBrightness = v, "0.00")),
                Ui.Caption(Ui.T("Todo pasa a rojo tenue para no perder la adaptación a la oscuridad. Atajo: ⌃⌘N. Baja también el brillo de la pantalla del Mac.").Replace("⌃⌘N", "Ctrl+N").Replace("Mac", "PC"))),
            Ui.Card(Ui.T("Archivos"), Ui.Row(Ui.T("Carpeta de imágenes"), Tb(s.SaveFolder, v => s.SaveFolder = v, 360))),
            Ui.Caption("Astrolabio " + AppInfo.Version + " · " + AppInfo.Author)));
    }
}

/// <summary>Registro de lo enviado y recibido, con diagnóstico.</summary>
public sealed class LogView : UserControl
{
    public LogView()
    {
        var st = AppState.Instance; var c = st.Client;
        var list = new StackPanel { Spacing = 1 };
        void Fill()
        {
            list.Children.Clear();
            foreach (var e in c.Log.TakeLast(400))
                list.Children.Add(Ui.Text($"{e.Date:T}  {e.Text}", 11, color: e.Level switch { LogLevel.Error => Ui.Bad, LogLevel.Warning => Ui.Warn, LogLevel.Traffic => Ui.Secondary, _ => Brushes.White }, wrap: true));
        }
        c.Log.CollectionChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(Fill);
        var traffic = new CheckBox { Content = Ui.T("Mostrar tráfico de red"), IsChecked = c.LogTraffic };
        traffic.IsCheckedChanged += (_, _) => c.LogTraffic = traffic.IsChecked == true;
        var diag = new StackPanel { Spacing = 2 };
        Content = new DockPanel
        {
            Children =
            {
                new Border { [DockPanel.DockProperty] = Dock.Top, Padding = new Thickness(14), Child = Ui.V(Ui.H(traffic,
                    Ui.Button(Ui.T("Diagnóstico"), async () =>
                    {
                        diag.Children.Clear();
                        void D(string t) => diag.Children.Add(Ui.Text(t, 12, wrap: true));
                        if (!c.IsConnected) { D(Ui.T("❌ Sin conexión. Comprueba que el Mac y el Seestar están en la misma wifi y que la IP es correcta.").Replace("Mac", "PC")); return; }
                        D(Ui.T("✅ Conectado a %@.", c.Host));
                        if (st.Settings.PemPath.Length == 0) D(Ui.T("⚠️ No hay clave PEM. Con firmware reciente el telescopio ignorará las órdenes."));
                        else D(c.IsAuthenticated ? Ui.T("✅ Autenticado.") : Ui.T("⚠️ Clave cargada pero sin autenticar: %@", c.AuthMessage));
                        if (c.FirmwareVersion > 0) D(Ui.T("ℹ️ Firmware %@ (%@).", c.FirmwareText, c.FirmwareVersion));
                        if (c.Battery is int b) D(b < 20 ? Ui.T("⚠️ Batería baja (%@ %%).", b) : Ui.T("✅ Batería %@ %%.", b));
                        var t0 = DateTime.Now;
                        try { await c.Send("test_connection", timeout: 5); D(Ui.T("✅ Responde a las órdenes (%.0f ms).", (DateTime.Now - t0).TotalMilliseconds)); }
                        catch { D(Ui.T("❌ No responde a las órdenes. Si no estás autenticado, revisa la clave PEM.")); }
                    }),
                    Ui.Button(Ui.T("Copiar"), async () => { var top = TopLevel.GetTopLevel(this); if (top?.Clipboard is { } cb) await cb.SetTextAsync(string.Join("\n", c.Log.Select(e => $"{e.Date:T} {e.Text}"))); }),
                    Ui.Button(Ui.T("Borrar"), () => c.Log.Clear())), diag) },
                new ScrollViewer { Content = new Border { Padding = new Thickness(14), Child = list } },
            },
        };
        Fill();
    }
}
