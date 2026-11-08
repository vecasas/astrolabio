using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using SkiaSharp;
using Astrolabio.Core;
using Astrolabio.Core.Imaging;

namespace Astrolabio.App.Views;

/// <summary>Abrir y guardar imágenes con SkiaSharp (incluido con Avalonia).</summary>
public static class ImageIOHelper
{
    public static EditableImage Load(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length == 0) throw new InvalidDataException(Strings.T("No se pudo abrir la imagen."));
        if (info.Length > 1_000_000_000) throw new InvalidDataException(Strings.T("La imagen es demasiado grande."));
        var name = Path.GetFileNameWithoutExtension(path);
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext is ".fit" or ".fits" or ".fts")
        {
            var r = PhotoEditor.ReadFits(File.ReadAllBytes(path)) ?? throw new InvalidDataException(Strings.T("No se pudo abrir la imagen."));
            return new EditableImage(r.Image, true, name, r.Header);
        }
        using var bmp = SKBitmap.Decode(path) ?? throw new InvalidDataException(Strings.T("No se pudo abrir la imagen."));
        if ((long)bmp.Width * bmp.Height > PhotoEditor.MaxPixels) throw new InvalidDataException(Strings.T("La imagen es demasiado grande."));
        int w = bmp.Width, h = bmp.Height;
        var rr = new float[w * h]; var gg = new float[w * h]; var bb = new float[w * h];
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
        {
            var c = bmp.GetPixel(x, y);
            rr[y * w + x] = c.Red * 257f; gg[y * w + x] = c.Green * 257f; bb[y * w + x] = c.Blue * 257f;
        }
        return new EditableImage(new LinearImage(w, h, rr, gg, bb), false, name);
    }

    public static SKBitmap ToSkia((int W, int H, float[] Rgb) img)
    {
        var bmp = new SKBitmap(img.W, img.H, SKColorType.Rgba8888, SKAlphaType.Opaque);
        var px = new byte[img.W * img.H * 4];
        for (var i = 0; i < img.W * img.H; i++)
        {
            px[4 * i] = (byte)(img.Rgb[3 * i] * 255); px[4 * i + 1] = (byte)(img.Rgb[3 * i + 1] * 255); px[4 * i + 2] = (byte)(img.Rgb[3 * i + 2] * 255); px[4 * i + 3] = 255;
        }
        System.Runtime.InteropServices.Marshal.Copy(px, 0, bmp.GetPixels(), px.Length);
        return bmp;
    }

    public static WriteableBitmap ToAvalonia(SKBitmap bmp)
    {
        var wb = new WriteableBitmap(new PixelSize(bmp.Width, bmp.Height), new Vector(96, 96), PixelFormat.Rgba8888, AlphaFormat.Opaque);
        using var fb = wb.Lock();
        var bytes = bmp.Bytes;
        for (var y = 0; y < bmp.Height; y++)
            System.Runtime.InteropServices.Marshal.Copy(bytes, y * bmp.Width * 4, fb.Address + y * fb.RowBytes, bmp.Width * 4);
        return wb;
    }

    /// <summary>Dibuja los nombres de los objetos y la rosa N/E (en una copia).</summary>
    public static void DrawLabels(SKBitmap bmp, ImageWcs wcs)
    {
        using var canvas = new SKCanvas(bmp);
        var size = Math.Max(11, Math.Min(bmp.Width, bmp.Height) * 0.022f);
        using var stroke = new SKPaint { Color = new SKColor(140, 204, 255, 230), IsStroke = true, StrokeWidth = Math.Max(1, size / 8), IsAntialias = true };
        using var font = new SKFont(SKTypeface.Default, size);
        using var fill = new SKPaint { Color = new SKColor(140, 204, 255, 230), IsAntialias = true };
        foreach (var l in SkyLabels.Labels(wcs, bmp.Width, bmp.Height))
        {
            canvas.DrawCircle((float)l.X, (float)l.Y, (float)l.Radius, stroke);
            canvas.DrawText(l.Name.Length == 0 ? l.Id : $"{l.Id} · {l.Name}", (float)(l.X + l.Radius * 0.75), (float)(l.Y - l.Radius * 0.75), font, fill);
        }
        if (SkyLabels.Compass(wcs) is { } c)
        {
            float ox = bmp.Width - size * 4, oy = size * 4, len = size * 2.6f;
            foreach (var (v, n) in new[] { (c.North, "N"), (c.East, "E") })
            {
                canvas.DrawLine(ox, oy, ox + (float)v.X * len, oy + (float)v.Y * len, stroke);
                canvas.DrawText(Strings.T(n), ox + (float)v.X * (len + size * 0.6f) - size * 0.3f, oy + (float)v.Y * (len + size * 0.6f) + size * 0.3f, font, fill);
            }
        }
        if (!wcs.Solved) canvas.DrawText(Strings.T("Posiciones aproximadas: la imagen no tiene solución astrométrica"), size, bmp.Height - size, font, fill);
    }

    public static void DrawCaption(SKBitmap bmp, string text)
    {
        using var canvas = new SKCanvas(bmp);
        var size = Math.Max(12, Math.Min(bmp.Width, bmp.Height) * 0.028f);
        using var font = new SKFont(SKTypeface.Default, size);
        using var shadow = new SKPaint { Color = new SKColor(0, 0, 0, 200), IsAntialias = true, ImageFilter = SKImageFilter.CreateBlur(size / 4, size / 4) };
        using var fill = new SKPaint { Color = new SKColor(255, 255, 255, 220), IsAntialias = true };
        canvas.DrawText(text, size, bmp.Height - size, font, shadow);
        canvas.DrawText(text, size, bmp.Height - size, font, fill);
    }

    /// <summary>JPEG, PNG o PNG de 16 bits.</summary>
    public static void Save(SKBitmap bmp, (int W, int H, float[] Rgb)? full16, string path, string format)
    {
        using var fs = File.Create(path);
        if (format == "PNG16" && full16 is { } f)
        {
            using var b16 = new SKBitmap(new SKImageInfo(f.W, f.H, SKColorType.Rgba16161616, SKAlphaType.Opaque));
            var px = new ushort[f.W * f.H * 4];
            for (var i = 0; i < f.W * f.H; i++) { px[4 * i] = (ushort)(f.Rgb[3 * i] * 65535); px[4 * i + 1] = (ushort)(f.Rgb[3 * i + 1] * 65535); px[4 * i + 2] = (ushort)(f.Rgb[3 * i + 2] * 65535); px[4 * i + 3] = 65535; }
            var bytes = new byte[px.Length * 2];
            Buffer.BlockCopy(px, 0, bytes, 0, bytes.Length);
            System.Runtime.InteropServices.Marshal.Copy(bytes, 0, b16.GetPixels(), bytes.Length);
            b16.Encode(fs, SKEncodedImageFormat.Png, 100);
            return;
        }
        bmp.Encode(fs, format == "JPEG" ? SKEncodedImageFormat.Jpeg : SKEncodedImageFormat.Png, 92);
    }
}

/// <summary>Retoque de fotos (Windows). El original no se modifica nunca.</summary>
public sealed class PhotoEditorView : UserControl
{
    private EditableImage? _src, _small;
    private double _scale = 1;
    private PhotoEdit _edit = new();
    private readonly List<SatelliteTrail> _trails = [];
    private readonly Stack<LinearImage> _undo = new();
    private bool _labels, _showOriginal, _marking;
    private Point? _first;
    private string? _path;
    private readonly Image _preview = new() { Stretch = Stretch.Uniform };
    private readonly TextBlock _msg = Ui.Caption("");
    private readonly StackPanel _trailList = new() { Spacing = 4 };
    private CancellationTokenSource? _cts;

    public PhotoEditorView()
    {
        Slider Sl(double v, double max, Func<double, PhotoEdit> set)
        {
            var s = new Slider { Minimum = 0, Maximum = max, Value = v, Width = 200 };
            s.PropertyChanged += (_, e) => { if (e.Property == Avalonia.Controls.Primitives.RangeBase.ValueProperty) { _edit = set(s.Value); Refresh(); } };
            return s;
        }
        CheckBox Cb(string t, bool v, Action<bool> set) { var c = new CheckBox { Content = t, IsChecked = v }; c.IsCheckedChanged += (_, _) => { set(c.IsChecked == true); Refresh(); }; return c; }
        var crop = new ComboBox { ItemsSource = new[] { Ui.T("Original"), "16:9", Ui.T("Cuadrado"), "4:5" }, SelectedIndex = 0, Width = 160 };
        crop.SelectionChanged += (_, _) => { _edit = _edit with { Crop = (CropAspect)Math.Max(0, crop.SelectedIndex) }; Refresh(); };
        var format = new ComboBox { ItemsSource = new[] { "JPEG", "PNG", "PNG16" }, SelectedIndex = 0, Width = 120 };
        var caption = new CheckBox { Content = Ui.T("Añadir un pie con el objeto, la exposición y la fecha") };
        var gxStrength = new Slider { Minimum = 0, Maximum = 1, Value = 0.5, Width = 160 };
        var gx = new StackPanel { Spacing = 4 };
        if (GraXpert.Find() is not null)
        {
            gx.Children.Add(Ui.H(Ui.Text(Ui.T("Intensidad"), 12), gxStrength));
            gx.Children.Add(Ui.Button(Ui.T("Quitar el gradiente con IA"), () => _ = RunGx(GraXpert.Tool.Background, gxStrength.Value)));
            gx.Children.Add(Ui.Button(Ui.T("Quitar el ruido con IA"), () => _ = RunGx(GraXpert.Tool.Denoise, gxStrength.Value)));
            gx.Children.Add(Ui.Button(Ui.T("Deshacer GraXpert"), () => { if (_src is not null && _undo.TryPop(out var prev)) { _src.Image = prev; MakeSmall(); Refresh(); } }));
            gx.Children.Add(Ui.Caption(Ui.T("Usa los modelos de IA de GraXpert en tu ordenador; la imagen no sale de él.")));
        }
        else gx.Children.Add(Ui.Caption(Ui.T("Instala GraXpert (gratuito, graxpert.com) para quitar el gradiente y el ruido con IA. Mientras tanto se usan los ajustes de Astrolabio.")));

        var controls = Ui.V(
            Ui.Card(Ui.T("Ajustes"),
                Cb(Ui.T("Quitar el gradiente (contaminación lumínica)"), true, v => _edit = _edit with { RemoveGradient = v }),
                Cb(Ui.T("Fondo neutro"), true, v => _edit = _edit with { NeutralBackground = v }),
                Ui.Row(Ui.T("Punto negro"), Sl(0.3, 1, v => _edit with { BlackPoint = v })),
                Ui.Row(Ui.T("Brillo"), Sl(0.4, 1, v => _edit with { Brightness = v })),
                Ui.Row(Ui.T("Ruido"), Sl(0.4, 1, v => _edit with { Noise = v })),
                Ui.Row(Ui.T("Ruido de color"), Sl(0.5, 1, v => _edit with { ColorNoise = v })),
                Ui.Row(Ui.T("Enfoque"), Sl(0.2, 1, v => _edit with { Sharpen = v })),
                Ui.Row(Ui.T("Saturación"), Sl(1.3, 2, v => _edit with { Saturation = v })),
                Ui.Row(Ui.T("Reducir estrellas"), Sl(0, 1, v => _edit with { StarReduction = v })),
                Ui.Row(Ui.T("Recorte"), crop),
                Cb(Ui.T("Comparar antes/después"), false, v => _showOriginal = v)),
            Ui.Card(Ui.T("Trazas de satélite"),
                Ui.H(Ui.Button(Ui.T("Buscar trazas"), () => _ = Detect()), Ui.Button(Ui.T("Marcar a mano"), () => { _marking = true; _first = null; _msg.Text = Ui.T("Haz clic en los dos extremos…"); })),
                _trailList),
            Ui.Card(Ui.T("Nombres de los objetos"), Cb(Ui.T("Mostrar nombres y la rosa N/E"), false, v => _labels = v),
                Ui.Caption(Ui.T("Esta imagen no trae solución astrométrica: las posiciones se estiman con el objeto central y el campo del Seestar, suponiendo el norte arriba. Pueden estar giradas."))),
            Ui.Card("GraXpert", gx),
            Ui.Card(Ui.T("Guardar"), caption, Ui.Row(Ui.T("Formato"), format),
                Ui.Button(Ui.T("Guardar una copia…"), () => _ = Save((string)format.SelectedItem!, caption.IsChecked == true), true),
                Ui.Caption(Ui.T("Se guarda una copia nueva; el original no se toca."))));
        _preview.PointerPressed += (_, e) =>
        {
            if (!_marking || _small is null || _preview.Bounds.Width <= 0) return;
            var p = e.GetPosition(_preview);
            var k = Math.Min(_preview.Bounds.Width / _small.Image.Width, _preview.Bounds.Height / _small.Image.Height);
            double ox = (_preview.Bounds.Width - _small.Image.Width * k) / 2, oy = (_preview.Bounds.Height - _small.Image.Height * k) / 2;
            var ip = new Point((p.X - ox) / k * _scale, (p.Y - oy) / k * _scale);
            if (_first is not Point f) { _first = ip; return; }
            _trails.Add(new SatelliteTrail { X1 = f.X, Y1 = f.Y, X2 = ip.X, Y2 = ip.Y, HalfWidth = 3 * _scale, Manual = true });
            _marking = false; _first = null; FillTrails(); Refresh();
        };
        var open = Ui.Button(Ui.T("Abrir una imagen…"), async () =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = false });
            if (files.FirstOrDefault()?.TryGetLocalPath() is string p) Open(p);
        });
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,360"), ColumnSpacing = 12 };
        var left = new DockPanel();
        var head = Ui.H(open, _msg); DockPanel.SetDock(head, Dock.Top);
        left.Children.Add(head); left.Children.Add(new Border { Background = Brushes.Black, Child = _preview });
        var right = Ui.Scroll(controls); Grid.SetColumn(right, 1);
        grid.Children.Add(left); grid.Children.Add(right);
        Content = grid;
    }

    public void Open(string path)
    {
        try
        {
            _src = ImageIOHelper.Load(path);
            _path = path;
            _trails.Clear(); _undo.Clear();
            MakeSmall(); FillTrails(); Refresh();
            _msg.Text = Path.GetFileName(path);
        }
        catch (Exception e) { _msg.Text = e.Message; }
    }

    private void MakeSmall()
    {
        if (_src is null) return;
        var f = Math.Max(1, (int)Math.Ceiling(Math.Max(_src.Image.Width, _src.Image.Height) / 1400.0));
        _scale = f;
        var img = _src.Image;
        if (f > 1)
        {
            int w = img.Width / f, h = img.Height / f;
            var r = new float[w * h]; var g = new float[w * h]; var b = new float[w * h];
            for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
            {
                float sr = 0, sg = 0, sb = 0;
                for (var dy = 0; dy < f; dy++) for (var dx = 0; dx < f; dx++) { var i = (y * f + dy) * img.Width + x * f + dx; sr += img.R[i]; sg += img.G[i]; sb += img.B[i]; }
                r[y * w + x] = sr / (f * f); g[y * w + x] = sg / (f * f); b[y * w + x] = sb / (f * f);
            }
            img = new LinearImage(w, h, r, g, b);
        }
        _small = new EditableImage(img, _src.IsLinear, _src.Name, _src.Header);
    }

    private ImageWcs? Wcs(EditableImage img)
    {
        if (ImageWcs.FromFits(_src!.Header, _src.Image.Width, _src.Image.Height) is { } w0)
        {
            var k = (double)_src.Image.Width / img.Image.Width;
            return w0 with { RefX = w0.RefX / k, RefY = w0.RefY / k, Cd11 = w0.Cd11 * k, Cd12 = w0.Cd12 * k, Cd21 = w0.Cd21 * k, Cd22 = w0.Cd22 * k };
        }
        return SkyLabels.ApproximateCenter(_src.Header, img.Name) is { } c
            ? ImageWcs.Estimate(c.RaHours, c.DecDeg, img.Image.Width, img.Image.Height, AppState.Instance.Settings.FovWidthDeg) : null;
    }

    private void Refresh()
    {
        if (_small is not { } s) return;
        _cts?.Cancel(); _cts = new CancellationTokenSource(); var ct = _cts.Token;
        var e = _showOriginal ? new PhotoEdit { RemoveGradient = false, NeutralBackground = false, Noise = 0, ColorNoise = 0, Sharpen = 0, Saturation = 1 } : _edit;
        var trails = _showOriginal ? [] : _trails.Select(t => new SatelliteTrail { X1 = t.X1 / _scale, Y1 = t.Y1 / _scale, X2 = t.X2 / _scale, Y2 = t.Y2 / _scale, HalfWidth = Math.Max(1, t.HalfWidth / _scale), Enabled = t.Enabled }).ToList();
        var wcs = _labels && e.Crop == CropAspect.Original ? Wcs(s) : null;
        _ = Task.Run(async () =>
        {
            await Task.Delay(120, ct);
            var rgb = PhotoEditor.Stretched(PhotoEditor.Process(s, e, trails), s.IsLinear, e);
            using var bmp = ImageIOHelper.ToSkia(rgb);
            if (wcs is not null) ImageIOHelper.DrawLabels(bmp, wcs);
            var wb = ImageIOHelper.ToAvalonia(bmp);
            if (!ct.IsCancellationRequested) Dispatcher.UIThread.Post(() => _preview.Source = wb);
        }, ct);
    }

    private async Task Detect()
    {
        if (_src is null) return;
        var found = await Task.Run(() => SatelliteTrails.Detect(_src.Image));
        _trails.RemoveAll(t => !t.Manual);
        _trails.AddRange(found);
        _msg.Text = found.Count == 0 ? Ui.T("No se han encontrado trazas de satélite.") : Ui.T("%@ trazas encontradas. Desmarca las que no lo sean.", found.Count);
        FillTrails(); Refresh();
    }

    private void FillTrails()
    {
        _trailList.Children.Clear();
        foreach (var t in _trails.ToList())
        {
            var cb = new CheckBox { Content = t.Manual ? Ui.T("Traza marcada a mano (%@ px)", (int)t.Length) : Ui.T("Traza de %@ px", (int)t.Length), IsChecked = t.Enabled };
            cb.IsCheckedChanged += (_, _) => { t.Enabled = cb.IsChecked == true; Refresh(); };
            _trailList.Children.Add(Ui.H(cb, Ui.Button("✕", () => { _trails.Remove(t); FillTrails(); Refresh(); })));
        }
    }

    private async Task RunGx(GraXpert.Tool tool, double strength)
    {
        if (_src is null) return;
        _msg.Text = Ui.T("GraXpert está trabajando… puede tardar unos minutos.");
        try
        {
            var out1 = await GraXpert.Run(tool, _src.Image, strength);
            if (out1.Width != _src.Image.Width || out1.Height != _src.Image.Height) throw new InvalidOperationException(Ui.T("GraXpert no devolvió ninguna imagen."));
            _undo.Push(_src.Image);
            _src.Image = out1;
            if (tool == GraXpert.Tool.Background) _edit = _edit with { RemoveGradient = false };
            MakeSmall(); Refresh();
            _msg.Text = Ui.T("GraXpert ha terminado.");
        }
        catch (Exception e) { _msg.Text = e.Message; }
    }

    private async Task Save(string format, bool caption)
    {
        if (_src is null || _path is null) return;
        var top = TopLevel.GetTopLevel(this);
        if (top is null) return;
        var ext = format == "JPEG" ? "jpg" : "png";
        var f = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = $"{Path.GetFileNameWithoutExtension(_path)}_retocada.{ext}" });
        if (f?.TryGetLocalPath() is not string dest) return;
        if (Path.GetFullPath(dest).Equals(Path.GetFullPath(_path), StringComparison.OrdinalIgnoreCase)) { _msg.Text = Ui.T("Elige otro nombre: el original no se sobrescribe."); return; }
        var src = _src; var e = _edit; var trails = _trails.ToList(); var wcs = _labels && e.Crop == CropAspect.Original ? Wcs(src) : null;
        var cap = caption ? $"{src.Name}  ·  Seestar S50 · Astrolabio" : null;
        await Task.Run(() =>
        {
            var rgb = PhotoEditor.Stretched(PhotoEditor.Process(src, e, trails), src.IsLinear, e);
            using var bmp = ImageIOHelper.ToSkia(rgb);
            if (wcs is not null) ImageIOHelper.DrawLabels(bmp, wcs);
            if (cap is not null) ImageIOHelper.DrawCaption(bmp, cap);
            ImageIOHelper.Save(bmp, format == "PNG16" && wcs is null && cap is null ? rgb : null, dest, format);
        });
        _msg.Text = Ui.T("Guardada en %@", Path.GetFileName(dest));
    }
}
