using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Astrolabio.Core;
using Astrolabio.Core.Model;
using Astrolabio.Core.Reports;
using Astrolabio.Core.Services;

namespace Astrolabio.App.Views;

/// <summary>Informes: lista de noches y un informe completo de cada una, descargable en PDF.</summary>
public sealed class ReportsView : UserControl
{
    private readonly Dictionary<DateTime, List<WeatherHour>> _weather = new();
    private readonly Dictionary<Guid, byte[]> _images = new();
    private readonly ContentControl _detail = new();
    private readonly TextBlock _status = Ui.Caption("");
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(4) };

    public ReportsView()
    {
        var st = AppState.Instance;
        var nights = NightSession.Group(st.History.All);
        if (nights.Count == 0)
        {
            Content = Ui.Scroll(Ui.V(Ui.Card(Ui.T("Todavía no hay sesiones"),
                Ui.Caption(Ui.T("Cuando apiles con el Seestar, o importes el álbum en Estadísticas, las sesiones aparecerán aquí.")))));
            return;
        }
        var list = new ListBox { Background = Brushes.Transparent, Width = 290 };
        foreach (var n in nights)
        {
            var item = new StackPanel { Spacing = 2, Margin = new Thickness(2, 4) };
            item.Children.Add(Ui.Text(n.Night.ToString("d MMM yyyy", Strings.Culture), 13, FontWeight.SemiBold));
            item.Children.Add(Ui.Caption(string.Join(", ", n.Targets)));
            item.Children.Add(Ui.Text($"🕑 {ReportFormat.Duration(n.IntegrationMinutes)}   ▤ {Ui.T("%d fotogramas", n.Frames)}", 11, color: Ui.AccentSoft));
            list.Items.Add(new ListBoxItem { Content = item, Tag = n });
        }
        list.SelectionChanged += async (_, _) => { if (list.SelectedItem is ListBoxItem { Tag: NightSession n }) await Show(n); };

        var left = new DockPanel();
        var header = Ui.Text($"{Ui.T("Sesiones")}  ({nights.Count})", 15, FontWeight.SemiBold);
        header.Margin = new Thickness(12, 12, 12, 6);
        DockPanel.SetDock(header, Dock.Top);
        left.Children.Add(header);
        left.Children.Add(list);

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };
        grid.Children.Add(new Border { Child = left, BorderBrush = Ui.CardStroke, BorderThickness = new Thickness(0, 0, 1, 0) });
        Grid.SetColumn(_detail, 1);
        grid.Children.Add(_detail);
        Content = grid;
        list.SelectedIndex = 0;
    }

    private static (string, double, double) Site()
    {
        var s = AppState.Instance.Settings;
        return (s.SiteName, s.Latitude, s.Longitude);
    }

    private ReportDocument Doc(NightSession n) =>
        ReportDocument.Make(n, _weather.GetValueOrDefault(n.Night), _images, Site());

    private async Task Show(NightSession n)
    {
        Render(n);
        _status.Text = "…";
        foreach (var r in n.Records.Where(r => !_images.ContainsKey(r.Id)))
        {
            try
            {
                if (r.ImagePath is string p && File.Exists(p)) _images[r.Id] = await File.ReadAllBytesAsync(p);
                else if (r.AlbumThumb is string u && Uri.TryCreate(u, UriKind.Absolute, out var uri) && uri.Scheme == "http" && NetPolicy.IsLocal(uri.Host))
                    _images[r.Id] = await Http.GetByteArrayAsync(uri);
            }
            catch { }
        }
        if (!_weather.ContainsKey(n.Night) && n.Records.All(r => r.Weather is null))
        {
            var (_, lat, lon) = Site();
            try
            {
                var to = n.End.AddHours(12) < DateTime.UtcNow ? n.End.AddHours(12) : DateTime.UtcNow;
                _weather[n.Night] = await WeatherService.History(n.Latitude ?? lat, n.Longitude ?? lon, n.Start.AddHours(-12), to);
            }
            catch { }
        }
        _status.Text = "";
        Render(n);
    }

    private void Render(NightSession n)
    {
        var doc = Doc(n);
        var pdf = Ui.Button(Ui.T("Descargar PDF"), async () => await SavePdf(n), primary: true);
        var title = new StackPanel { Spacing = 2 };
        title.Children.Add(Ui.Text(doc.Title, 22, FontWeight.Bold));
        title.Children.Add(Ui.Caption(doc.Subtitle));
        var top = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
        top.Children.Add(title);
        Grid.SetColumn(_status, 1); _status.VerticalAlignment = VerticalAlignment.Center; _status.Margin = new Thickness(0, 0, 10, 0);
        if (_status.Parent is Panel old) old.Children.Remove(_status);
        top.Children.Add(_status);
        Grid.SetColumn(pdf, 2); pdf.VerticalAlignment = VerticalAlignment.Center;
        top.Children.Add(pdf);

        var blocks = new List<Control> { top, Ui.Wrap(Rows(Ui.T("Resumen"), doc.Summary), Rows(Ui.T("Condiciones"), doc.Conditions)) };
        blocks.Add(Ui.Text(Ui.T("Objetos observados"), 15, FontWeight.SemiBold));
        foreach (var o in doc.Objects)
        {
            var rows = RowList(o.Rows);
            Control body = rows;
            if (o.Image is { } bytes)
            {
                try
                {
                    var img = new Image { Source = new Bitmap(new MemoryStream(bytes)), MaxWidth = 260, MaxHeight = 260, Margin = new Thickness(14, 0, 0, 0), VerticalAlignment = VerticalAlignment.Top };
                    var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
                    g.Children.Add(rows); Grid.SetColumn(img, 1); g.Children.Add(img);
                    body = g;
                }
                catch { }
            }
            blocks.Add(o.Subtitle.Length > 0 ? Ui.Card(o.Title, Ui.Caption(o.Subtitle), body) : Ui.Card(o.Title, body));
        }
        if (doc.Device.Count > 0) blocks.Add(Rows(Ui.T("Telescopio"), doc.Device));
        blocks.Add(Ui.Card(Ui.T("Eventos y errores"), doc.Events.Count == 0
            ? Ui.Caption(Ui.T("No hay eventos registrados para esta sesión."))
            : Ui.V(doc.Events.Select(e => (Control)new SelectableTextBlock { Text = e, FontFamily = new FontFamily("Consolas,monospace"), FontSize = 11, Foreground = Brushes.White }).ToArray())));
        blocks.Add(Ui.Caption(doc.Footer));
        _detail.Content = Ui.Scroll(Ui.V(blocks.ToArray()));
    }

    private static StackPanel RowList(List<ReportRow> rows)
    {
        var p = new StackPanel { Spacing = 4 };
        foreach (var r in rows)
        {
            var v = Ui.Text(r.Value, 12); v.TextWrapping = TextWrapping.Wrap; v.TextAlignment = TextAlignment.Right; v.MaxWidth = 340;
            p.Children.Add(Ui.Row(r.Label, v));
        }
        return p;
    }

    private static Border Rows(string title, List<ReportRow> rows)
    {
        var c = Ui.Card(title, RowList(rows));
        c.MinWidth = 380;
        return c;
    }

    private async Task SavePdf(NightSession n)
    {
        var top = TopLevel.GetTopLevel(this);
        if (top is null) return;
        var file = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            SuggestedFileName = $"{AppVersion.Name}-{Ui.T("Informe")}-{n.Night:yyyy-MM-dd}.pdf",
            DefaultExtension = "pdf",
            FileTypeChoices = [new FilePickerFileType("PDF") { Patterns = ["*.pdf"] }],
        });
        if (file?.TryGetLocalPath() is not string path) return;
        try
        {
            await File.WriteAllBytesAsync(path, ReportPdf.Render(Doc(n)));
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception e) { _status.Text = Ui.T("No se pudo guardar el PDF") + ": " + e.Message; }
    }
}
