using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Model;
using Astrolabio.Core.Protocol;
using Astrolabio.Core.Services;

namespace Astrolabio.App.Views;

/// <summary>Foto DSS2 de una zona del cielo (NASA SkyView), encuadrada como el campo del Seestar.</summary>
public sealed class SkyImage : Border
{
    private static readonly Dictionary<string, Bitmap> Cache = new();

    public SkyImage(double raHours, double decDeg, double sizeArcmin, double fovW, double fovH, double width)
    {
        var scale = Math.Max(1, sizeArcmin / 60 * 1.25 / fovH);
        double w = fovW * scale, h = fovH * scale;
        Width = width; Height = width * fovH / fovW;
        Background = Brushes.Black; CornerRadius = new CornerRadius(10); ClipToBounds = true;
        var grid = new Grid();
        var img = new Image { Stretch = Stretch.UniformToFill };
        grid.Children.Add(img);
        grid.Children.Add(new TextBlock { Text = Ui.T("Buscando la imagen…"), FontSize = 10, Foreground = Ui.Secondary, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        if (scale > 1.05)
            grid.Children.Add(new Border { BorderBrush = Ui.Warn, BorderThickness = new Thickness(1.2), Width = Width / scale, Height = Height / scale, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        Child = grid;
        var px = 360; var py = (int)(px * h / w);
        var url = string.Create(System.Globalization.CultureInfo.InvariantCulture,
            $"https://skyview.gsfc.nasa.gov/current/cgi/runquery.pl?Position={raHours * 15:F5},{decDeg:F5}&Survey=DSS2%20Red&Pixels={px},{py}&Size={w:F4},{h:F4}&Scaling=Sqrt&Return=JPEG");
        _ = Load(url, img, (TextBlock)grid.Children[1]);
    }

    private static async Task Load(string url, Image img, TextBlock label)
    {
        try
        {
            if (!Cache.TryGetValue(url, out var bmp))
            {
                var data = await WeatherService.Http.GetByteArrayAsync(url);
                bmp = Stretch(new Bitmap(new MemoryStream(data)));
                Cache[url] = bmp;
            }
            img.Source = bmp; label.IsVisible = false;
        }
        catch { label.Text = Ui.T("Imagen no disponible (sin internet)"); }
    }

    /// <summary>Negro en el fondo del cielo (percentil 40), blanco en el 99,7 y una curva suave.</summary>
    private static Bitmap Stretch(Bitmap src)
    {
        int w = src.PixelSize.Width, h = src.PixelSize.Height;
        if (w < 100 || h < 100) return src;
        var buf = new byte[w * h * 4];
        var handle = GCHandle.Alloc(buf, GCHandleType.Pinned);
        try { src.CopyPixels(new PixelRect(0, 0, w, h), handle.AddrOfPinnedObject(), buf.Length, w * 4); } finally { handle.Free(); }
        var hist = new int[256];
        for (var i = 0; i < w * h; i++) hist[buf[4 * i + 1]]++;
        int Pct(double p) { var target = (int)(w * h * p); var acc = 0; for (var i = 0; i < 256; i++) { acc += hist[i]; if (acc >= target) return i; } return 255; }
        double black = Pct(0.40), white = Math.Max(black + 8, Pct(0.997));
        var lut = new byte[256];
        for (var i = 0; i < 256; i++) lut[i] = (byte)(Math.Pow(Math.Clamp((i - black) / (white - black), 0, 1), 0.75) * 255);
        var wb = new WriteableBitmap(new PixelSize(w, h), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Opaque);
        using var fb = wb.Lock();
        var row = new byte[w * 4];
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++) { var v = lut[buf[(y * w + x) * 4 + 1]]; row[4 * x] = v; row[4 * x + 1] = v; row[4 * x + 2] = v; row[4 * x + 3] = 255; }
            Marshal.Copy(row, 0, fb.Address + y * fb.RowBytes, w * 4);
        }
        return wb;
    }
}

/// <summary>Resumen compacto de la recomendación (duración · exposición · filtro).</summary>
public static class Advice
{
    public static Control Summary(DeepSkyObject o)
    {
        var st = AppState.Instance; var s = st.Settings;
        var a = CaptureAdvice.Make(o, s.Latitude, s.Longitude, s.MinAltitude, st.Night, st.Client.CurrentGain ?? s.Gain);
        var p = Ui.H(Ui.Pill($"⏱ {a.Minutes:F0} min", Ui.AccentSoft), Ui.Pill($"📷 {a.ExposureMs / 1000} s", Ui.AccentSoft),
            Ui.Pill(a.LpFilter ? Ui.T("Filtro LP") : Ui.T("Sin LP"), a.LpFilter ? Ui.Good : Ui.Secondary));
        ToolTip.SetTip(p, string.Join("\n", a.Reasons));
        return p;
    }
}

/// <summary>Ventana «Antes de ir»: muestra y deja cambiar duración, exposición, ganancia y filtro LP.</summary>
public sealed class GotoConfirmWindow : Window
{
    private static CancellationTokenSource? _stackTimer;

    public GotoConfirmWindow(DeepSkyObject obj, Action<string> onResult)
    {
        var st = AppState.Instance; var s = st.Settings; var c = st.Client;
        Title = Ui.T("Antes de ir a %@", obj.Id);
        Width = 760; SizeToContent = SizeToContent.Height; Background = Ui.Navy; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var a = CaptureAdvice.Make(obj, s.Latitude, s.Longitude, s.MinAltitude, st.Night, c.CurrentGain ?? s.Gain);
        var minutes = new NumericUpDown { Value = (decimal)a.Minutes, Minimum = 10, Maximum = 240, Increment = 10, FormatString = "0", Width = 140 };
        var exposure = new ComboBox { ItemsSource = new[] { "10 s", "20 s", "30 s" }, SelectedIndex = a.ExposureMs / 10_000 - 1, Width = 140 };
        var gain = new NumericUpDown { Value = a.Gain, Minimum = c.GainRange?.Lo ?? 0, Maximum = Math.Max(c.GainRange?.Hi ?? 120, a.Gain), Increment = 5, FormatString = "0", Width = 140 };
        var lp = new CheckBox { Content = Ui.T("Usar el filtro antipolución"), IsChecked = a.LpFilter };
        var stop = new CheckBox { Content = Ui.T("Parar el apilado al cumplir la duración"), IsChecked = true };
        var status = Ui.Caption("");
        var reasons = Ui.V(a.Reasons.Select(r => (Control)Ui.Text("ⓘ " + r, 12, wrap: true)).ToArray());
        var go = Ui.Button(Ui.T("Ir y apilar"), async () =>
        {
            var exp = ((exposure.SelectedIndex < 0 ? 2 : exposure.SelectedIndex) + 1) * 10_000; var g = (int)(gain.Value ?? 80);
            var mins = (double)(minutes.Value ?? 60); var useLp = lp.IsChecked == true; var stopAtEnd = stop.IsChecked == true;
            status.Text = Ui.T("Aplicando exposición y ganancia…");
            try { await c.SetExposure(exp); await c.SetGain(g); s.ExposureMs = exp; s.Gain = g; s.Save(); }
            catch (Exception e) { c.AddLog(Ui.T("No se pudieron aplicar los ajustes: %@", e.Message), LogLevel.Warning); }
            status.Text = Ui.T("Apuntando a %@…", obj.Id);
            var (ok, msg) = await c.GotoAndStack(obj.Id, obj.RaHours, obj.DecDeg, useLp);
            if (ok && stopAtEnd)
            {
                _stackTimer?.Cancel(); _stackTimer = new CancellationTokenSource(); var ct = _stackTimer.Token;
                _ = Task.Run(async () =>
                {
                    try { await Task.Delay(TimeSpan.FromMinutes(mins), ct); } catch { return; }
                    try { await c.StopStack(); } catch { }
                    c.AddLog(Ui.T("Duración cumplida: apilado de %@ detenido.", obj.Id));
                    s.Notify(Ui.T("Apilado terminado"), Ui.T("%@: %@ minutos completados.", obj.Id, (int)mins));
                });
                msg += Ui.T(" Se parará a los %@ min.", (int)mins);
            }
            onResult(msg);
            Close();
        }, true);
        go.IsEnabled = c.IsConnected && a.AltitudeNow >= 10;
        var form = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), RowDefinitions = new RowDefinitions("Auto,Auto,Auto,Auto,Auto"), ColumnSpacing = 14, RowSpacing = 8 };
        void AddRow(int r, string label, Control ctl) { var t = Ui.Text(label, 12, color: Ui.Secondary); t.VerticalAlignment = VerticalAlignment.Center; Grid.SetRow(t, r); Grid.SetRow(ctl, r); Grid.SetColumn(ctl, 1); form.Children.Add(t); form.Children.Add(ctl); }
        AddRow(0, Ui.T("Duración"), minutes); AddRow(1, Ui.T("Exposición"), exposure); AddRow(2, Ui.T("Ganancia"), gain);
        AddRow(3, Ui.T("Filtro LP"), lp); AddRow(4, Ui.T("Al terminar"), stop);
        var buttons = Ui.H(Ui.Button(Ui.T("Cancelar"), Close), go);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        Content = new StackPanel
        {
            Margin = new Thickness(22), Spacing = 14,
            Children =
            {
                Ui.Text(Ui.T("Antes de ir a %@", obj.Id), 20, FontWeight.Bold),
                Ui.Caption(obj.Name.Length == 0 ? obj.Kind.Label() : $"{obj.LocalizedName} · {obj.Kind.Label()}"),
                Ui.H(new SkyImage(obj.RaHours, obj.DecDeg, obj.SizeArcmin, s.FovWidthDeg, s.FovHeightDeg, 130),
                     Ui.V(Ui.H(Ui.Tile(Ui.T("Duración sugerida"), $"{a.Minutes:F0} min"), Ui.Tile(Ui.T("Exposición"), $"{a.ExposureMs / 1000} s", Ui.T("Ganancia %@", a.Gain)),
                               Ui.Tile(Ui.T("Filtro LP"), a.LpFilter ? Ui.T("Sí") : Ui.T("No"))), reasons)),
                Ui.Text(Ui.T("Ajustes para esta sesión"), 14, FontWeight.SemiBold), form, status, buttons,
                c.IsConnected ? new Control() : Ui.Caption(Ui.T("Conecta el telescopio para apuntar.")),
            },
        };
    }
}
