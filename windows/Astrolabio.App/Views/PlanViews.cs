using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Model;

namespace Astrolabio.App.Views;

/// <summary>Planificar la noche: todos los objetos ordenados, con su ventana útil.</summary>
public sealed class PlannerView : UserControl
{
    public PlannerView()
    {
        var st = AppState.Instance; var s = st.Settings;
        var search = new TextBox { Watermark = Ui.T("Buscar"), Width = 240 };
        var list = new StackPanel { Spacing = 4 };
        var msg = Ui.Caption("");
        void Fill()
        {
            list.Children.Clear();
            var header = new Grid { ColumnDefinitions = new ColumnDefinitions("260,60,90,90,80,60,60,120,Auto") };
            string[] cols = ["Objeto", "Nota", "Tiempo útil", "Altura máx.", "Mejor hora", "Luna", "Nubes", "Encuadre", ""];
            for (var i = 0; i < cols.Length; i++) { var t = Ui.Text(Ui.T(cols[i] == "" ? " " : cols[i]), 12, FontWeight.SemiBold, Ui.Secondary); Grid.SetColumn(t, i); header.Children.Add(t); }
            list.Children.Add(header);
            foreach (var f in st.Forecasts.Where(f => string.IsNullOrEmpty(search.Text) || f.Object.DisplayName.Contains(search.Text, StringComparison.OrdinalIgnoreCase)))
            {
                var row = new Grid { ColumnDefinitions = header.ColumnDefinitions.Count > 0 ? new ColumnDefinitions("260,60,90,90,80,60,60,120,Auto") : new() };
                string[] v = [f.Object.DisplayName, $"{f.Score:F0}", $"{f.MinutesUsable / 60:F1} h", $"{f.MaxAltitude:F0}°", Ui.Time(f.BestTime), $"{f.MoonSeparation:F0}°", f.MeanCloud is double c ? $"{c:F0} %" : "—", f.Fit.Label];
                for (var i = 0; i < v.Length; i++) { var t = Ui.Text(v[i], 12, color: i == 1 && f.Score > 50 ? Ui.Good : null); Grid.SetColumn(t, i); row.Children.Add(t); }
                var add = Ui.Button(Ui.T("Añadir"), () => { st.Plan.Add(f.Object, Math.Min(120, Math.Max(30, Math.Round(f.MinutesUsable * 0.5 / 15) * 15)), f.Fit); msg.Text = Ui.T("%@ añadido al plan.", f.Object.Id); });
                add.Padding = new Thickness(8, 2);
                Grid.SetColumn(add, 8); row.Children.Add(add);
                list.Children.Add(row);
            }
        }
        search.TextChanged += (_, _) => Fill();
        var n = st.Night;
        Content = Ui.Scroll(Ui.V(
            Ui.H(Ui.Text(s.SiteName, 14, FontWeight.SemiBold),
                 Ui.Caption(Ui.T("Noche cerrada: %@ – %@", Ui.Time(n?.DuskStart), Ui.Time(n?.DawnEnd)), false), search),
            msg, list));
        st.TonightUpdated += () => Avalonia.Threading.Dispatcher.UIThread.Post(Fill);
        Fill();
    }
}

/// <summary>Sesión automática: el plan y su ejecución.</summary>
public sealed class SessionView : UserControl
{
    public SessionView()
    {
        var st = AppState.Instance; var r = st.Runner; var c = st.Client;
        var list = new StackPanel { Spacing = 6 };
        void FillPlan()
        {
            list.Children.Clear();
            if (st.Plan.Items.Count == 0) list.Children.Add(Ui.Caption(Ui.T("El plan está vacío. Añade objetos desde «Planificar la noche» o «Mosaicos».")));
            foreach (var it in st.Plan.Items.ToList())
            {
                var status = it.Status switch { PlanItem.ItemStatus.Done => "✅", PlanItem.ItemStatus.Running => "▶", PlanItem.ItemStatus.Failed => "❌", PlanItem.ItemStatus.Skipped => "⏭", _ => "○" };
                var remove = Ui.Button("✕", () => { st.Plan.Items.Remove(it); st.Plan.Save(); FillPlan(); });
                list.Children.Add(Ui.H(Ui.Text(status), Ui.Text(Catalog.Find(it.Name)?.DisplayName ?? it.Name, 13, FontWeight.SemiBold),
                    Ui.Caption($"{it.Minutes:F0} min{(it.IsMosaic ? " · " + Ui.T("mosaico %@×%@", it.MosaicColumns, it.MosaicRows) : "")}{(it.LpFilter ? " · " + Ui.T("filtro LP") : "")}", false), remove));
            }
            list.Children.Add(Ui.Caption(Ui.T("Total: %@ min en %@ objetos", (int)st.Plan.Items.Sum(i => i.Minutes), st.Plan.Items.Count)));
        }
        CheckBox Cb(string t, bool v, Action<bool> set) { var cb = new CheckBox { Content = t, IsChecked = v }; cb.IsCheckedChanged += (_, _) => set(cb.IsChecked == true); return cb; }
        var phase = Ui.Text(r.PhaseLabel, 14, FontWeight.SemiBold, Ui.AccentSoft);
        var log = new StackPanel { Spacing = 2 };
        void Update()
        {
            phase.Text = r.PhaseLabel;
            log.Children.Clear();
            foreach (var m in r.Messages.TakeLast(60)) log.Children.Add(Ui.Text(m, 11, wrap: true));
            FillPlan();
        }
        r.PropertyChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(Update);
        r.Messages.CollectionChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(Update);
        var s = st.Settings;
        bool Charging() => c.ChargerStatus is "Charging" or "Full";
        (double Hours, double Drain, double End)? Estimate()
        {
            if (c.Battery is not int b) return null;
            var hours = BatteryEstimate.PlanHours(st.Plan.Items);
            var drain = BatteryEstimate.DrainPerHour(st.History.All);
            return (hours, drain, BatteryEstimate.ExpectedAtEnd(b, hours, drain));
        }
        var battery = Ui.Caption("");
        void UpdateBattery()
        {
            var e = Estimate();
            battery.Text = e is not { } x || x.Hours <= 0 ? "" : Charging() ? Ui.T("Batería: el telescopio está cargando.")
                : Ui.T("Batería prevista al terminar: %@ %% (plan de %@ h, consumo medio %@ %%/h).", Math.Max(0, (int)x.End), x.Hours.ToString("F1", System.Globalization.CultureInfo.InvariantCulture), (int)x.Drain);
            battery.Foreground = e is { } y && !Charging() && y.End < BatteryEstimate.Reserve ? Ui.Warn : Ui.Secondary;
        }
        var start = Ui.Button(Ui.T("Empezar"), async () =>
        {
            if (c.Battery is int b && Estimate() is { } e && !BatteryEstimate.IsEnough(b, Charging(), e.Hours, e.Drain) &&
                !await Ask.YesNo(Ui.T("Puede que la batería no aguante el plan"),
                    Ui.T("El Seestar tiene un %@ %% y el plan dura unas %@ h; con tu consumo medio (%@ %%/h) terminaría sin batería. Conecta el cargador o acorta el plan.",
                        b, e.Hours.ToString("F1", System.Globalization.CultureInfo.InvariantCulture), (int)e.Drain),
                    Ui.T("Empezar igualmente"), Ui.T("Cancelar")))
                return;
            r.Start(c, s, st.Plan);
        }, true);
        var endAction = new ComboBox { ItemsSource = Enum.GetValues<EndAction>().Select(a => a.Label()).ToList(), SelectedIndex = (int)s.EndAction, Width = 260 };
        endAction.SelectionChanged += (_, _) => { if (endAction.SelectedIndex >= 0) { s.EndAction = (EndAction)endAction.SelectedIndex; s.Save(); } };
        c.PropertyChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(UpdateBattery);
        UpdateBattery();
        var run = Ui.Card(Ui.T("Ejecutar el plan"),
            Cb(Ui.T("Esperar a la noche astronómica"), r.WaitForDark, v => r.WaitForDark = v),
            Cb(Ui.T("Pausar si se prevén nubes (más de %@ %%)", (int)st.Settings.MaxCloudCover), r.PauseForClouds, v => r.PauseForClouds = v),
            Cb(Ui.T("Parar al amanecer"), r.StopAtDawn, v => r.StopAtDawn = v),
            Ui.Row(Ui.T("Al terminar"), endAction),
            Cb(Ui.T("Crear los oscuros antes de terminar"), s.DarksAtEnd, v => { s.DarksAtEnd = v; s.Save(); }),
            battery,
            Ui.H(start, Ui.Button(Ui.T("Saltar objeto"), () => r.Skip(c)), Ui.Button(Ui.T("Detener"), () => r.Stop(c))),
            Ui.Row(Ui.T("Estado"), phase),
            Ui.Caption(Ui.T("Deja el Mac encendido y la app abierta durante la sesión. Activa los avisos al móvil en Ajustes.").Replace("Mac", "PC")));
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,380"), ColumnSpacing = 14 };
        var left = Ui.V(Ui.Card(Ui.T("Planificar la noche"), list, Ui.H(Ui.Button(Ui.T("Reiniciar estados"), () => { foreach (var i in st.Plan.Items) { i.Status = PlanItem.ItemStatus.Pending; i.StackedFrames = 0; } st.Plan.Save(); FillPlan(); }),
            Ui.Button(Ui.T("Vaciar"), () => { st.Plan.Items.Clear(); st.Plan.Save(); FillPlan(); }))));
        var right = Ui.V(run, Ui.Card(Ui.T("Qué está pasando"), log));
        Grid.SetColumn(right, 1);
        grid.Children.Add(left); grid.Children.Add(right);
        Content = Ui.Scroll(grid);
        Update();
    }
}
