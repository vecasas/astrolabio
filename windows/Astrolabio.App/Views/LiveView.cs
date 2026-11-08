using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Astrolabio.Core;
using Astrolabio.Core.Imaging;

namespace Astrolabio.App.Views;

/// <summary>Vista en directo: imagen apilada procesada, controles de estirado y guardado.</summary>
public sealed class LiveView : UserControl
{
    public LiveView()
    {
        var st = AppState.Instance; var live = st.Live; var c = st.Client;
        var image = new Image { Stretch = Stretch.Uniform };
        var placeholder = Ui.Text(c.IsConnected ? Ui.T("Esperando la primera imagen apilada…") : Ui.T("Conecta el telescopio para ver la imagen."), color: Ui.Secondary);
        placeholder.HorizontalAlignment = HorizontalAlignment.Center; placeholder.VerticalAlignment = VerticalAlignment.Center;
        var zoom = new LayoutTransformControl { Child = image };
        var scroller = new ScrollViewer { Content = zoom, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto };
        var area = new Grid { Background = Brushes.Black, Children = { scroller, placeholder } };
        var zoomSlider = new Slider { Minimum = 1, Maximum = 8, Value = 1, Width = 140 };
        zoomSlider.PropertyChanged += (_, e) => { if (e.Property == Slider.ValueProperty) zoom.LayoutTransform = new ScaleTransform(zoomSlider.Value, zoomSlider.Value); };
        image.DoubleTapped += (_, _) => zoomSlider.Value = zoomSlider.Value > 1 ? 1 : 2.5;
        var info = Ui.Caption(live.Info); var frames = Ui.Caption(""); var status = Ui.Caption(live.StreamStatus);
        void Update()
        {
            image.Source = live.Image; placeholder.IsVisible = live.Image is null;
            info.Text = live.Info + (live.LastStarMetrics is { } m
                ? "  ·  " + Ui.T("Nitidez: HFR %@ px (%@ estrellas)", m.Hfr.ToString("F2", System.Globalization.CultureInfo.InvariantCulture), m.Stars) : ""); status.Text = live.StreamStatus; frames.Text = Ui.T("%@ fotogramas apilados", c.StackedFrames);
        }
        live.PropertyChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(Update);

        var o = live.Options;
        Slider Sl(double min, double max, double v, Action<double> set)
        {
            var sl = new Slider { Minimum = min, Maximum = max, Value = v };
            sl.PropertyChanged += (_, e) => { if (e.Property == Slider.ValueProperty) set(sl.Value); };
            return sl;
        }
        CheckBox Cb(string t, bool v, Action<bool> set) { var cb = new CheckBox { Content = t, IsChecked = v }; cb.IsCheckedChanged += (_, _) => set(cb.IsChecked == true); return cb; }
        var auto = Cb(Ui.T("Actualizar sola"), live.AutoRefresh, v => live.AutoRefresh = v);
        var preview = Cb(Ui.T("Vista previa sin apilar"), live.IsPreviewing, v => { if (v) live.StartPreview(); else live.StopPreview(); });
        var saveMsg = Ui.Caption("");
        var controls = Ui.V(
            Ui.Card(Ui.T("Imagen"), info, frames, status, auto, preview, Ui.Row(Ui.T("Zoom"), zoomSlider), Ui.Caption(Ui.T("Doble clic en la imagen para acercar o volver a verla entera.")),
                Ui.Button(Ui.T("Pedir imagen"), live.RequestStacked)),
            Ui.Card(Ui.T("Estirado"),
                Ui.Text(Ui.T("Brillo del fondo"), 12), Sl(0.05, 0.45, o.TargetBackground, v => live.Options = live.Options with { TargetBackground = v }),
                Ui.Text(Ui.T("Recorte de sombras"), 12), Sl(0.5, 5, o.ShadowsClip, v => live.Options = live.Options with { ShadowsClip = v }),
                Ui.Text(Ui.T("Saturación"), 12), Sl(0.5, 2.5, o.Saturation, v => live.Options = live.Options with { Saturation = v }),
                Cb(Ui.T("Canales enlazados"), o.Linked, v => live.Options = live.Options with { Linked = v })),
            Ui.Card(Ui.T("Mejorar"),
                Cb(Ui.T("Recortar bordes del apilado"), o.CropEdges, v => live.Options = live.Options with { CropEdges = v }),
                Cb(Ui.T("Quitar gradiente (contaminación lumínica)"), o.RemoveGradient, v => live.Options = live.Options with { RemoveGradient = v }),
                Cb(Ui.T("Fondo neutro y color de las estrellas"), o.ColorBalance, v => live.Options = live.Options with { ColorBalance = v }),
                Cb(Ui.T("Reducir ruido"), o.Denoise, v => live.Options = live.Options with { Denoise = v }),
                Ui.Button(Ui.T("Restablecer"), () => live.Options = new ProcessingOptions())),
            Ui.Card(Ui.T("Guardar"),
                Ui.Button(Ui.T("Guardar PNG y FITS"), () =>
                {
                    try
                    {
                        var name = c.ViewTarget ?? c.LastEvents.GetValueOrDefault("AutoGoto")?.Data["target_name"]?.ToString() ?? "Seestar";
                        var files = live.Save(st.Settings.SaveFolderPath, name);
                        saveMsg.Text = Ui.T("Guardado en %@: %@", st.Settings.SaveFolderPath, string.Join(", ", files.Select(Path.GetFileName)));
                    }
                    catch (Exception e) { saveMsg.Text = e.Message; }
                }, true),
                Ui.Button(Ui.T("Abrir carpeta"), () => OpenFolder(st.Settings.SaveFolderPath)), saveMsg,
                Ui.Caption(Ui.T("El FITS conserva los datos lineales para procesarlos en Siril o GraXpert."))));
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,300") };
        var side = new ScrollViewer { Content = new Border { Padding = new Thickness(12), Child = controls } };
        Grid.SetColumn(side, 1);
        grid.Children.Add(area); grid.Children.Add(side);
        Content = grid;
        Update();
    }

    public static void OpenFolder(string path)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo { FileName = path, UseShellExecute = true }); } catch { }
    }
}
