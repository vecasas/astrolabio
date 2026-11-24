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
