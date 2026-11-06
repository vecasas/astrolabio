using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Protocol;

namespace Astrolabio.App.Views;

/// <summary>Lienzo de la carta estelar: proyección estereográfica con el cenit en el centro.</summary>
public sealed class SkyCanvas : Control
{
    public double HourOffset { get; set; }
    public double Zoom { get; set; } = 1;
    public Vector Pan { get; set; }
    public double DsoMag { get; set; } = 10;
    public bool ShowLines { get; set; } = true;
    public bool ShowNames { get; set; } = true;
    public event Action<string, string>? Selected;
    private Point? _drag;

    private DateTime Date => DateTime.UtcNow.AddHours(HourOffset);

    private (double R, Point C, double Lst) Proj()
    {
        var s = AppState.Instance.Settings;
        var r = Math.Min(Bounds.Width, Bounds.Height) / 2 - 24;
        return (r * Zoom, new Point(Bounds.Width / 2 + Pan.X, Bounds.Height / 2 + Pan.Y), Astro.LocalSiderealTime(Date, s.Longitude));
    }

    private Point? ToScreen(double raDeg, double decDeg, double minAlt = 0)
    {
        var (R, c, lst) = Proj(); var lat = AppState.Instance.Settings.Latitude * Astro.Deg;
        var ha = (lst - raDeg) * Astro.Deg; var d = decDeg * Astro.Deg;
        var alt = Math.Asin(Math.Clamp(Math.Sin(d) * Math.Sin(lat) + Math.Cos(d) * Math.Cos(lat) * Math.Cos(ha), -1, 1));
        if (alt * Astro.Rad < minAlt) return null;
        var az = Math.Atan2(-Math.Sin(ha) * Math.Cos(d), Math.Sin(d) * Math.Cos(lat) - Math.Cos(d) * Math.Cos(ha) * Math.Sin(lat));
        var r = R * Math.Tan((Math.PI / 2 - alt) / 2);
        return new Point(c.X - r * Math.Sin(az), c.Y - r * Math.Cos(az));
    }

    private Point AltAzPoint(double alt, double az)
    {
        var (R, c, _) = Proj(); var r = R * Math.Tan((90 - alt) * Astro.Deg / 2);
        return new Point(c.X - r * Math.Sin(az * Astro.Deg), c.Y - r * Math.Cos(az * Astro.Deg));
    }

    public override void Render(DrawingContext ctx)
    {
        var (R, c, _) = Proj();
        ctx.FillRectangle(Ui.Deep, new Rect(Bounds.Size));
        ctx.DrawEllipse(new SolidColorBrush(Color.FromRgb(6, 14, 34)), new Pen(Ui.Accent, 1.5), c, R, R);
        using (ctx.PushGeometryClip(new EllipseGeometry(new Rect(c.X - R, c.Y - R, 2 * R, 2 * R))))
        {
            if (ShowLines)
            {
                var pen = new Pen(new SolidColorBrush(Color.FromArgb(90, 82, 161, 255)), 0.8);
                foreach (var line in SkyCatalog.ConstellationLines)
                    for (var i = 1; i < line.Length; i++)
                        if (ToScreen(line[i - 1].Ra, line[i - 1].Dec, -10) is Point a && ToScreen(line[i].Ra, line[i].Dec, -10) is Point b) ctx.DrawLine(pen, a, b);
            }
            var limit = Zoom > 2.5 ? 5.5 : Zoom > 1.5 ? 5.0 : 4.6;
            foreach (var s in SkyCatalog.Stars.Where(s => s.Mag <= limit))
            {
                if (ToScreen(s.Ra, s.Dec) is not Point p) continue;
                var r = Math.Max(0.6, 3.6 - s.Mag * 0.62);
                ctx.DrawEllipse(Brushes.White, null, p, r, r);
                if (ShowNames && s.Name.Length > 0 && s.Mag < (Zoom > 1.5 ? 2.6 : 1.6))
                    ctx.DrawText(new FormattedText(s.Name, Strings.Culture, FlowDirection.LeftToRight, Typeface.Default, 9, Ui.Secondary), p + new Vector(r + 3, -6));
            }
            if (ShowNames && ShowLines)
                foreach (var l in SkyCatalog.Labels.Where(l => l.Rank <= (Zoom > 1.6 ? 3 : 1)))
                    if (ToScreen(l.Ra, l.Dec, 5) is Point p)
                        ctx.DrawText(new FormattedText(l.Name.ToUpper(Strings.Culture), Strings.Culture, FlowDirection.LeftToRight, Typeface.Default, 9, new SolidColorBrush(Color.FromArgb(120, 140, 199, 255))), p);
            foreach (var o in Catalog.Objects.Where(o => o.Magnitude <= DsoMag))
            {
                if (ToScreen(o.RaHours * 15, o.DecDeg) is not Point p) continue;
                var r = Math.Clamp(o.SizeArcmin / 60 * R / 90 * 2.2, 3.5, 14);
                var col = o.Kind switch { ObjectKind.Galaxy => Color.FromRgb(242, 166, 242), ObjectKind.Nebula or ObjectKind.Snr => Color.FromRgb(115, 242, 191), ObjectKind.Planetary => Color.FromRgb(115, 217, 255), ObjectKind.Globular => Color.FromRgb(255, 217, 115), _ => Color.FromRgb(255, 242, 153) };
                ctx.DrawEllipse(null, new Pen(new SolidColorBrush(col), 1.2), p, r, o.Kind == ObjectKind.Galaxy ? r * 0.65 : r);
                if (ShowNames && (o.Id.StartsWith('M') || Zoom > 2))
                    ctx.DrawText(new FormattedText(o.Id, Strings.Culture, FlowDirection.LeftToRight, Typeface.Default, 8.5, new SolidColorBrush(col)), p + new Vector(-8, r + 1));
            }
            foreach (var n in Astro.PlanetNames)
                if (Astro.Planet(n, Date) is { } pl && ToScreen(pl.Ra * 15, pl.Dec) is Point p)
                {
                    ctx.DrawEllipse(new SolidColorBrush(Color.FromRgb(255, 217, 140)), null, p, 4, 4);
                    ctx.DrawText(new FormattedText(Strings.T(n), Strings.Culture, FlowDirection.LeftToRight, Typeface.Default, 10, new SolidColorBrush(Color.FromRgb(255, 224, 166))), p + new Vector(7, -7));
                }
            var m = Astro.Moon(Date);
            if (ToScreen(m.Ra * 15, m.Dec) is Point mp) ctx.DrawEllipse(Brushes.WhiteSmoke, null, mp, 9, 9);
            var cl = AppState.Instance.Client;
            if (HourOffset == 0 && cl.Ra is double tra && cl.Dec is double tdec && ToScreen(tra * 15, tdec, -5) is Point tp)
            {
                var pen = new Pen(Ui.Warn, 1.5);
                ctx.DrawEllipse(null, pen, tp, 9, 9);
                ctx.DrawLine(pen, tp - new Vector(15, 0), tp - new Vector(5, 0)); ctx.DrawLine(pen, tp + new Vector(5, 0), tp + new Vector(15, 0));
                ctx.DrawLine(pen, tp - new Vector(0, 15), tp - new Vector(0, 5)); ctx.DrawLine(pen, tp + new Vector(0, 5), tp + new Vector(0, 15));
            }
        }
        foreach (var (key, az) in new[] { ("N", 0.0), ("NE", 45.0), ("E", 90.0), ("SE", 135.0), ("S", 180.0), ("SO", 225.0), ("O", 270.0), ("NO", 315.0) })
        {
            var p = AltAzPoint(-6 / Math.Max(1, Zoom), az);
            ctx.DrawText(new FormattedText(Strings.T(key), Strings.Culture, FlowDirection.LeftToRight, new Typeface(FontFamily.Default, FontStyle.Normal, FontWeight.Bold), key.Length == 1 ? 13 : 10, Ui.AccentSoft), p - new Vector(6, 8));
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e) { _drag = e.GetPosition(this); base.OnPointerPressed(e); }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if (_drag is Point d && e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        { var p = e.GetPosition(this); Pan += p - d; _drag = p; InvalidateVisual(); }
        base.OnPointerMoved(e);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        var p = e.GetPosition(this);
        if (_drag is Point d && (p - d).Length < 3) Pick(p);
        _drag = null;
        base.OnPointerReleased(e);
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        Zoom = Math.Clamp(Zoom * (e.Delta.Y > 0 ? 1.2 : 1 / 1.2), 1, 12);
        if (Zoom == 1) Pan = default;
        InvalidateVisual();
        base.OnPointerWheelChanged(e);
    }

    private void Pick(Point p)
    {
        var s = AppState.Instance.Settings;
        (string Title, string Detail, double D)? best = null;
        void Consider(string t, string d, Point? q, double bonus = 0)
        {
            if (q is not Point x) return;
            var dist = (x - p).Length - bonus;
            if (dist < 16 && (best is null || dist < best.Value.D)) best = (t, d, dist);
        }
        foreach (var o in Catalog.Objects.Where(o => o.Magnitude <= DsoMag))
            Consider(o.Id, $"{o.DisplayName}\n{o.Kind.Label()} · mag {o.Magnitude:F1} · {o.SizeArcmin:F0}′\n{Astro.FormatRA(o.RaHours)}  {Astro.FormatDec(o.DecDeg)}", ToScreen(o.RaHours * 15, o.DecDeg), 2);
        foreach (var n in Astro.PlanetNames)
            if (Astro.Planet(n, Date) is { } pl) Consider(Strings.T(n), $"{Strings.T(n)}\n{Astro.FormatRA(pl.Ra)}  {Astro.FormatDec(pl.Dec)}", ToScreen(pl.Ra * 15, pl.Dec), 3);
        foreach (var st in SkyCatalog.Stars.Where(x => x.Mag <= 4.5))
            Consider(st.Name.Length > 0 ? st.Name : Strings.T("Estrella"), Strings.T("Estrella de magnitud %.1f", st.Mag), ToScreen(st.Ra, st.Dec), st.Mag < 2 ? 1 : -2);
        if (best is { } b) Selected?.Invoke(b.Title, b.Detail);
    }
}

public sealed class SkyChartView : UserControl
{
    public SkyChartView()
    {
        var canvas = new SkyCanvas();
        var time = Ui.Text("", 13, FontWeight.SemiBold);
        var slider = new Slider { Minimum = -6, Maximum = 14, Value = 0, Width = 260, TickFrequency = 0.25, IsSnapToTickEnabled = true };
        void UpdateTime() { time.Text = DateTime.Now.AddHours(slider.Value).ToString("ddd d MMM HH:mm", Strings.Culture) + (slider.Value == 0 ? " · " + Ui.T("Ahora") : ""); }
        slider.PropertyChanged += (_, e) => { if (e.Property == Slider.ValueProperty) { canvas.HourOffset = slider.Value; UpdateTime(); canvas.InvalidateVisual(); } };
        var selTitle = Ui.Text(Ui.T("Cómo se usa"), 15, FontWeight.SemiBold);
        var selDetail = Ui.Text(Ui.T("Haz clic en una estrella, un objeto o un planeta para ver sus datos. Arrastra para moverte, pellizca o usa la lupa para acercarte y mueve la barra para ver el cielo a otra hora."), 12, wrap: true);
        var goHost = new ContentControl();
        var msg = Ui.Caption("");
        canvas.Selected += (t, d) =>
        {
            selTitle.Text = t; selDetail.Text = d;
            goHost.Content = Catalog.Find(t) is { } o && AppState.Instance.Client.IsConnected && slider.Value == 0
                ? Ui.V(Advice.Summary(o), Ui.Button(Ui.T("Ir y apilar…"), async () => await new GotoConfirmWindow(o, m => msg.Text = m).ShowDialog(TopLevel.GetTopLevel(this) as Window ?? throw new InvalidOperationException()), true))
                : null;
        };
        CheckBox Cb(string t, bool v, Action<bool> set) { var c = new CheckBox { Content = t, IsChecked = v }; c.IsCheckedChanged += (_, _) => { set(c.IsChecked == true); canvas.InvalidateVisual(); }; return c; }
        var side = Ui.V(
            Ui.Card(Ui.T("Capas"), Cb(Ui.T("Líneas de constelaciones"), true, v => canvas.ShowLines = v), Cb(Ui.T("Nombres"), true, v => canvas.ShowNames = v)),
            Ui.Card(selTitle.Text ?? "", selDetail, goHost, msg));
        ((StackPanel)((Border)side.Children[1]).Child!).Children[0] = selTitle;
        var top = Ui.H(time, slider, Ui.Button(Ui.T("Ahora"), () => slider.Value = 0),
            Ui.Button("−", () => { canvas.Zoom = Math.Max(1, canvas.Zoom / 1.4); canvas.InvalidateVisual(); }),
            Ui.Button("+", () => { canvas.Zoom = Math.Min(12, canvas.Zoom * 1.4); canvas.InvalidateVisual(); }),
            Ui.Button(Ui.T("Ver todo el cielo"), () => { canvas.Zoom = 1; canvas.Pan = default; canvas.InvalidateVisual(); }));
        top.Margin = new Thickness(12);
        var left = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        left.Children.Add(top); left.Children.Add(canvas);
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,300") };
        var sideScroll = new ScrollViewer { Content = new Border { Padding = new Thickness(12), Child = side } };
        Grid.SetColumn(sideScroll, 1);
        grid.Children.Add(left); grid.Children.Add(sideScroll);
        Content = grid;
        UpdateTime();
        Avalonia.Threading.DispatcherTimer.Run(() => { canvas.InvalidateVisual(); return IsVisible; }, TimeSpan.FromSeconds(30));
    }
}

/// <summary>Luna realista: mapa LRO proyectado sobre una esfera e iluminado desde el Sol.</summary>
public static class MoonRenderer
{
    private static (int W, int H, byte[] Bgra)? _tex;

    private static (int W, int H, byte[] Bgra)? Texture()
    {
        if (_tex is not null) return _tex;
        using var s = typeof(Catalog).Assembly.GetManifestResourceStream("Astrolabio.Core.Data.moon.jpg");
        if (s is null) return null;
        var bmp = new Bitmap(s);
        int w = bmp.PixelSize.Width, h = bmp.PixelSize.Height; var buf = new byte[w * h * 4];
        var handle = GCHandle.Alloc(buf, GCHandleType.Pinned);
        try { bmp.CopyPixels(new PixelRect(0, 0, w, h), handle.AddrOfPinnedObject(), buf.Length, w * 4); } finally { handle.Free(); }
        return _tex = (w, h, buf);
    }

    public static WriteableBitmap? Render(int size, double elongation)
    {
        if (Texture() is not { } tex) return null;
        var theta = Math.PI - elongation * Math.PI / 180; double sx = Math.Sin(theta), sz = Math.Cos(theta);
        var wb = new WriteableBitmap(new PixelSize(size, size), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Premul);
        var outp = new byte[size * size * 4]; var r = size / 2.0 - 1;
        for (var py = 0; py < size; py++)
        for (var px = 0; px < size; px++)
        {
            double y = (r - py + 0.5) / r, x = (px - r + 0.5) / r, d2 = x * x + y * y;
            if (d2 > 1) continue;
            var z = Math.Sqrt(1 - d2);
            double lon = Math.Atan2(x, z), lat = Math.Asin(y);
            var tu = Math.Clamp((int)((lon / (2 * Math.PI) + 0.5) * tex.W), 0, tex.W - 1);
            var tv = Math.Clamp((int)((0.5 - lat / Math.PI) * tex.H), 0, tex.H - 1);
            var ti = 4 * (tv * tex.W + tu);
            var mu0 = x * sx + z * sz;
            var soft = Math.Clamp((mu0 + 0.04) / 0.08, 0, 1);
            var lit = mu0 > 0 ? 2 * mu0 / (mu0 + z) : 0;
            var light = lit * soft * 1.05 + 0.06 * (1 - soft) * (0.6 + 0.4 * z);
            var o = 4 * (py * size + px);
            outp[o] = (byte)Math.Clamp(tex.Bgra[ti] * light * 1.04, 0, 255);
            outp[o + 1] = (byte)Math.Clamp(tex.Bgra[ti + 1] * light, 0, 255);
            outp[o + 2] = (byte)Math.Clamp(tex.Bgra[ti + 2] * light * 0.98, 0, 255);
            outp[o + 3] = 255;
        }
        using var fb = wb.Lock();
        for (var y = 0; y < size; y++) Marshal.Copy(outp, y * size * 4, fb.Address + y * fb.RowBytes, size * 4);
        return wb;
    }
}

public sealed class MoonView : UserControl
{
    public MoonView()
    {
        var st = AppState.Instance; var s = st.Settings; var c = st.Client; var now = DateTime.UtcNow;
        var m = Astro.Moon(now); var ph = Astro.MoonPhase(now);
        var aa = Astro.AltAz(m.Ra, m.Dec, now, s.Latitude, s.Longitude);
        var dist = Ephemeris.MoonDistanceKm(now);
        var rs = Ephemeris.Compute(now.AddHours(-1), 26, 300, 0.125, Ephemeris.MoonAltitude(s.Latitude, s.Longitude));
        var phases = Ui.V(Ephemeris.NextPhases(now).Select(p => (Control)Ui.Row(Ui.T(p.Name), p.Date.ToLocalTime().ToString("ddd d MMM HH:mm", Strings.Culture))).ToArray());
        var calendar = new WrapPanel();
        for (var d = 0; d < 30; d++)
        {
            var day = DateTime.Today.AddDays(d).AddHours(22).ToUniversalTime();
            var mm = Astro.Moon(day);
            calendar.Children.Add(new StackPanel
            {
                Margin = new Thickness(0, 0, 10, 10),
                Children = { new Image { Source = MoonRenderer.Render(72, Ephemeris.MoonElongation(day)), Width = 34, Height = 34 },
                             Ui.Text(day.ToLocalTime().ToString("d MMM", Strings.Culture), 9, color: mm.Illumination < 0.25 ? Ui.Good : Ui.Secondary) },
            });
        }
        var advice = m.Illumination switch
        {
            < 0.25 => "Luna poco iluminada: noche ideal para galaxias y nebulosas débiles.",
            < 0.6 => aa.Alt > 0 ? "Luna a medias: elige objetos lejos de ella o nebulosas de emisión con el filtro LP." : "La Luna aún no ha salido: aprovecha ahora para los objetos más débiles.",
            _ => aa.Alt > 0 ? "Luna brillante: mejor cúmulos, estrellas dobles, planetas… o la propia Luna. Las nebulosas de emisión aguantan con el filtro LP." : "Luna brillante pero bajo el horizonte: aprovecha mientras no sale.",
        };
        Content = Ui.Scroll(Ui.V(
            Ui.H(new StackPanel { Width = 300, Spacing = 8, Children = { new Image { Source = MoonRenderer.Render(500, Ephemeris.MoonElongation(now)), Width = 250, Height = 250 },
                    Ui.Text(ph.Name, 24, FontWeight.Bold), Ui.Caption(Ui.T("Iluminada al %.0f %% · %.1f días", m.Illumination * 100, ph.Age), false) } },
                Ui.V(Ui.H(Ui.Tile(Ui.T("Altura ahora"), $"{aa.Alt:F0}°", Ui.T("Acimut %.0f° · %@", aa.Az, aa.Alt > 0 ? Ui.T("sobre el horizonte") : Ui.T("bajo el horizonte"))),
                          Ui.Tile(Ui.T("Distancia"), Ui.T("%.0f km", dist), Ui.T("Diámetro aparente %.1f′", 2 * Math.Atan(1737.4 / dist) * Astro.Rad * 60))),
                     Ui.H(Ui.Tile(Ui.T("Sale"), Ui.Time(rs.Rise)), Ui.Tile(Ui.T("Culmina"), Ui.Time(rs.Transit), $"{rs.MaxAltitude:F0}°"), Ui.Tile(Ui.T("Se pone"), Ui.Time(rs.Set))),
                     Ui.Card(Ui.T("Y para el cielo profundo…"), Ui.Text(Ui.T(advice), 12, wrap: true)))),
            Ui.Card(Ui.T("Próximas fases"), phases),
            Ui.Card(Ui.T("Los próximos 30 días"), calendar, Ui.Caption(Ui.T("En verde, las noches con poca Luna: las mejores para galaxias y nebulosas débiles."))),
            Ui.Card(Ui.T("Fotografiar la Luna con el Seestar"),
                Ui.H(Ui.Button(Ui.T("Modo Luna del Seestar"), async () => await Ui.Run(Ui.T("Modo Luna"), c.StartMoonView), true),
                     Ui.Button(Ui.T("GoTo a la Luna"), async () => { var p = Astro.Moon(DateTime.UtcNow); await Ui.Run(Ui.T("GoTo Luna"), () => c.GotoAndWait("Luna", p.Ra, p.Dec)); }),
                     Ui.Button(Ui.T("Parar"), async () => await Ui.Run(Ui.T("Parar"), c.StopView)),
                     Ui.Button(Ui.T("Volver al modo cielo profundo"), async () => await Ui.Run(Ui.T("Modo cielo profundo"), c.StartStarView))),
                Ui.Caption(aa.Alt > 0 ? Ui.T("El modo Luna sigue la Luna y muestra la imagen en «Vista en directo». Para un mosaico o un vídeo, graba con la app y apílalo en «Apilador planetario».") : Ui.T("Ahora la Luna está bajo el horizonte.")))));
    }
}

public sealed class PlanetsView : UserControl
{
    public PlanetsView()
    {
        var st = AppState.Instance; var s = st.Settings; var c = st.Client; var now = DateTime.UtcNow;
        var cards = new WrapPanel();
        var msg = Ui.Caption("");
        foreach (var name in Astro.PlanetNames)
        {
            if (Astro.Planet(name, now) is not { } p) continue;
            var aa = Astro.AltAz(p.Ra, p.Dec, now, s.Latitude, s.Longitude);
            var geo = Ephemeris.Geometry(name, now); var mag = Ephemeris.Magnitude(name, now); var diam = Ephemeris.DiameterArcsec(name, p.Distance);
            var rs = Ephemeris.Compute(now.AddHours(-1), 26, 600, 0, Ephemeris.PlanetAltitude(name, s.Latitude, s.Longitude));
            var nearSun = (geo?.Elongation ?? 90) < 15;
            var status = nearSun ? Ui.Pill(Ui.T("Junto al Sol"), Ui.Warn) : aa.Alt > 10 ? Ui.Pill(Ui.T("Visible ahora"), Ui.Good)
                : rs.Rise is DateTime r && r > now ? Ui.Pill(Ui.T("Sale a las %@", Ui.Time(r)), Ui.AccentSoft) : Ui.Pill(Ui.T("Bajo"), Ui.Secondary);
            var go = Ui.Button(Ui.T("GoTo"), async () =>
            {
                msg.Text = Ui.T("Apuntando a %@…", Ui.T(name));
                try { var pos = Astro.Planet(name, DateTime.UtcNow)!.Value; msg.Text = await c.GotoAndWait(name, pos.Ra, pos.Dec) ? Ui.T("%@ centrado. Pulsa «Modo planeta» para seguirlo.", Ui.T(name)) : Ui.T("El GoTo a %@ no terminó bien.", Ui.T(name)); }
                catch (Exception e) { msg.Text = e.Message; }
            }, true);
            var scan = Ui.Button(Ui.T("Modo planeta"), async () => await Ui.Run(Ui.T("Modo planeta"), c.StartPlanetScan));
            go.IsEnabled = scan.IsEnabled = c.IsConnected && aa.Alt >= 10 && !nearSun;
            var card = Ui.Card(Ui.T(name), status,
                Ui.Row(Ui.T("Altura"), Ui.T("%.0f° (acimut %.0f°)", aa.Alt, aa.Az)),
                Ui.Row(Ui.T("Magnitud"), mag is double mg ? $"{mg:F1}" : "—"),
                Ui.Row(Ui.T("Tamaño"), diam is double dm ? $"{dm:F1}″" : "—"),
                Ui.Row(Ui.T("Distancia"), Ui.T("%.2f UA · %.0f millones de km", p.Distance, p.Distance * 149.6)),
                Ui.Row(Ui.T("Separación del Sol"), geo is { } g ? $"{g.Elongation:F0}°" : "—"),
                Ui.Row(Ui.T("Sale / culmina / se pone"), $"{Ui.Time(rs.Rise)} · {Ui.Time(rs.Transit)} · {Ui.Time(rs.Set)}"),
                Ui.Caption(Ui.T(Ephemeris.PlanetInfo[name].Note)), Ui.H(go, scan));
            card.Width = 340; card.Margin = new Thickness(0, 0, 14, 14);
            cards.Children.Add(card);
        }
        Content = Ui.Scroll(Ui.V(msg, cards, Ui.Card(Ui.T("Sol"), Ui.Text(Ui.T("Para observar el Sol usa la app oficial con el filtro solar puesto. Astrolabio nunca apunta al Sol."), 12, wrap: true))));
    }
}
