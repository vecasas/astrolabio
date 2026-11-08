using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Model;
using Astrolabio.Core.Protocol;

namespace Astrolabio.App.Views;

/// <summary>Las próximas 7 noches valoradas, con la mejor destacada.</summary>
public sealed class WeekOutlookCard : UserControl
{
    public WeekOutlookCard()
    {
        var st = AppState.Instance;
        var body = new StackPanel { Spacing = 6 };
        void Fill()
        {
            body.Children.Clear();
            var nights = WeekOutlook.Nights(DateTime.Now, st.Settings.Latitude, st.Settings.Longitude, st.Weather);
            var best = WeekOutlook.Best(nights);
            if (best is not null)
                body.Children.Add(Ui.Text(Ui.T("Mejor noche: %@ (%@ puntos)", best.Date.ToString("dddd d", Strings.Culture), best.Score), 13, FontWeight.SemiBold, Ui.Good));
            var bars = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Height = 170, VerticalAlignment = VerticalAlignment.Bottom };
            foreach (var n in nights)
            {
                var col = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Bottom, Width = 46 };
                col.Children.Add(Ui.Caption(n.Score.ToString(CultureInfo.InvariantCulture), false));
                col.Children.Add(new Border { Height = Math.Max(4, n.Score), Width = 30, CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Center,
                    Background = n == best ? Ui.Good : new SolidColorBrush(Ui.AccentColor, n.Cloud is null ? 0.25 : 0.7) });
                col.Children.Add(Ui.Caption(n.Date.ToString("ddd", Strings.Culture), false));
                col.Children.Add(Ui.Caption(n.Cloud is double c ? $"☁ {c:F0} %" : "—", false));
                col.Children.Add(Ui.Caption($"☾ {n.MoonIllumination * 100:F0} %", false));
                bars.Children.Add(col);
            }
            body.Children.Add(bars);
            body.Children.Add(Ui.Caption(Ui.T("Puntos: nubes durante la noche (lo que más pesa), Luna y horas de oscuridad. Sin previsión, la barra sale tenue.")));
        }
        st.WeatherUpdated += () => Dispatcher.UIThread.Post(Fill);
        Fill();
        Content = Ui.Card(Ui.T("La semana"), body);
    }
}

/// <summary>Cometas más brillantes que la magnitud 12 visibles esta noche.</summary>
public sealed class CometsTonightCard : UserControl
{
    public CometsTonightCard(TextBlock msg)
    {
        var st = AppState.Instance; var store = CometStore.Shared;
        var body = new StackPanel { Spacing = 6 };
        async Task Fill()
        {
            await store.RefreshIfNeeded();
            var n = st.Night ?? Astro.NightFor(DateTime.Now, st.Settings.Latitude, st.Settings.Longitude);
            var s = st.Settings;
            var list = await Task.Run(() => Comets.Visible(store.Orbits, n, s.Latitude, s.Longitude, s.MinAltitude));
            body.Children.Clear();
            if (list.Count == 0)
                body.Children.Add(Ui.Caption(store.Orbits.Count == 0 ? store.Error ?? Ui.T("Descargando las órbitas de los cometas…")
                    : Ui.T("Ningún cometa más brillante que la magnitud 12 sube lo bastante esta noche.")));
            foreach (var c in list.Take(6))
            {
                var info = Ui.V(Ui.Text(c.Orbit.Name, 13, FontWeight.SemiBold),
                    Ui.Caption(Ui.T("mag %@ · máx. %@° a las %@ · a %@ UA de la Tierra", c.Position.Magnitude.ToString("F1", CultureInfo.InvariantCulture),
                        (int)c.MaxAltitude, c.Best?.ToLocalTime().ToString("t", Strings.Culture) ?? "—", c.Position.Delta.ToString("F2", CultureInfo.InvariantCulture))));
                var go = Ui.Button(Ui.T("Ir y apilar"), async () =>
                {
                    var p = Comets.Position(c.Orbit, DateTime.UtcNow);
                    msg.Text = Ui.T("Apuntando a %@…", c.Orbit.Name);
                    msg.Text = (await st.Client.GotoAndStack(SafeName.FileComponent(c.Orbit.Name), p.RaHours, p.DecDeg, false)).Message;
                });
                go.IsEnabled = st.Client.IsConnected;
                var add = Ui.Button(Ui.T("Al plan"), () =>
                {
                    st.Plan.Items.Add(new PlanItem { Name = c.Orbit.Name, RaHours = c.Position.RaHours, DecDeg = c.Position.DecDeg, Minutes = 60, Comet = c.Orbit.Name });
                    st.Plan.Save();
                    msg.Text = Ui.T("%@ añadido al plan.", c.Orbit.Name);
                });
                body.Children.Add(Ui.H(info, go, add));
            }
            body.Children.Add(Ui.Caption(Ui.T("Órbitas del Minor Planet Center, actualizadas cada día. En la sesión automática el telescopio vuelve a apuntar al cometa cuando se ha movido.")));
        }
        _ = Fill();
        Content = Ui.Card(Ui.T("Cometas esta noche"), body);
    }
}

/// <summary>Listas Messier y Caldwell y maratón Messier.</summary>
public sealed class ListsView : UserControl
{
    private readonly ContentControl _body = new();
    private readonly TextBlock _msg = Ui.Caption("");
    private Dictionary<string, double> _tonight = new();
    private ListStatus _status = ListStatus.All;

    public ListsView()
    {
        var tabs = Ui.H(Ui.Button(Ui.T("Messier"), () => Show(ObservingList.Messier)), Ui.Button(Ui.T("Caldwell"), () => Show(ObservingList.Caldwell)),
            Ui.Button(Ui.T("Maratón Messier"), ShowMarathon));
        Content = Ui.Scroll(Ui.V(tabs, _msg, _body));
        _ = Init();
    }

    private async Task Init()
    {
        var s = AppState.Instance.Settings;
        var n = Astro.NightFor(DateTime.Now, s.Latitude, s.Longitude);
        _tonight = await Task.Run(() =>
        {
            var d = new Dictionary<string, double>();
            foreach (var l in new[] { ObservingList.Messier, ObservingList.Caldwell })
                foreach (var e in ObservingLists.Entries(l))
                    if (e.Object is { } o) d[o.Id] = ObservingLists.UsableTonight(o, n, s.Latitude, s.Longitude, s.MinAltitude);
            return d;
        });
        Show(ObservingList.Messier);
    }

    private void Show(ObservingList list)
    {
        var st = AppState.Instance;
        var imaged = ObservingLists.Imaged(st.History.All);
        var entries = ObservingLists.Entries(list);
        var done = entries.Count(e => e.Object is { } o && imaged.Contains(o.Id));
        var status = new ComboBox { ItemsSource = Enum.GetValues<ListStatus>().Select(x => Ui.T(ObservingLists.StatusKey(x))).ToList(), SelectedIndex = (int)_status, Width = 300 };
        status.SelectionChanged += (_, _) => { _status = (ListStatus)Math.Max(0, status.SelectedIndex); Show(list); };
        var export = Ui.Button(Ui.T("Exportar CSV"), async () =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var f = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = $"astrolabio_{list.ToString().ToLowerInvariant()}.csv" });
            if (f?.TryGetLocalPath() is string p) { File.WriteAllText(p, ObservingLists.Csv(list, imaged, _tonight)); _msg.Text = Ui.T("Exportado a %@", p); }
        });
        var rows = new StackPanel { Spacing = 3 };
        foreach (var e in entries)
        {
            var o = e.Object;
            var isDone = o is not null && imaged.Contains(o.Id);
            var mins = o is null ? 0 : _tonight.GetValueOrDefault(o.Id);
            var show = _status switch { ListStatus.Done => isDone, ListStatus.Pending => !isDone, ListStatus.PendingTonight => !isDone && mins > 0, _ => true };
            if (!show) continue;
            Control Cell(string t, double w, IBrush? c = null) { var tb = Ui.Text(t, 12, color: c); tb.Width = w; return tb; }
            var row = Ui.H(Cell(e.Label, 50), Cell(o?.Id ?? "—", 90), Cell(o?.LocalizedName ?? "", 220, Ui.Secondary), Cell(o?.Kind.Label() ?? "", 150),
                Cell(o?.Magnitude.ToString("F1", CultureInfo.InvariantCulture) ?? "", 45),
                Cell(mins > 0 ? Ui.T("%@ h", (mins / 60).ToString("F1", CultureInfo.InvariantCulture)) : Ui.T("No sale"), 80, mins > 0 ? null : Ui.Secondary),
                Cell(isDone ? "✓ " + Ui.T("Hecho") : Ui.T("Pendiente"), 100, isDone ? Ui.Good : Ui.Secondary));
            if (o is not null) row.Children.Add(Ui.Button(Ui.T("Al plan"), () => { st.Plan.Add(o); st.Plan.Save(); _msg.Text = Ui.T("%@ añadido al plan.", o.Id); }));
            rows.Children.Add(row);
        }
        _body.Content = Ui.V(Ui.H(Ui.Text(Ui.T("%@ de %@ fotografiados", done, entries.Count), 15, FontWeight.SemiBold),
            new ProgressBar { Minimum = 0, Maximum = entries.Count, Value = done, Width = 200 }, status, export), rows);
    }

    private void ShowMarathon()
    {
        var st = AppState.Instance; var s = st.Settings;
        var date = new CalendarDatePicker { SelectedDate = DateTime.Today, Width = 180 };
        var minutes = new NumericUpDown { Value = 4, Minimum = 2, Maximum = 15, Increment = 1, FormatString = "0", Width = 120 };
        var list = new StackPanel { Spacing = 2 };
        var summary = Ui.Text("", 14, FontWeight.SemiBold);
        (List<MarathonStep> Steps, List<DeepSkyObject> Missed) result = ([], []);
        async Task Fill()
        {
            var n = Astro.NightFor(date.SelectedDate ?? DateTime.Today, s.Latitude, s.Longitude);
            var m = (double)(minutes.Value ?? 4);
            result = await Task.Run(() => Marathon.Plan(n, s.Latitude, s.Longitude, minutesPerObject: m));
            summary.Text = Ui.T("%@ de 110 objetos en orden · %@ no se pueden ver esa noche desde tu lugar", result.Steps.Count, result.Missed.Count);
            list.Children.Clear();
            foreach (var st2 in result.Steps)
                list.Children.Add(Ui.Text($"{st2.Time.ToLocalTime():HH:mm}   {st2.Object.Id,-5}  {st2.Object.Kind.Label(),-22} {(int)st2.Altitude}°   {st2.Object.LocalizedName}", 12));
            if (result.Missed.Count > 0) list.Children.Add(Ui.Caption(Ui.T("No visibles: %@", string.Join(", ", result.Missed.Select(o => o.Id)))));
        }
        date.SelectedDateChanged += async (_, _) => await Fill();
        minutes.ValueChanged += async (_, _) => await Fill();
        var use = Ui.Button(Ui.T("Usar como plan de la noche"), () =>
        {
            var m = (double)(minutes.Value ?? 4);
            st.Plan.Items.Clear();
            foreach (var x in result.Steps)
                st.Plan.Items.Add(new PlanItem { Name = x.Object.Id, RaHours = x.Object.RaHours, DecDeg = x.Object.DecDeg, Minutes = m, Autofocus = false });
            st.Plan.Save();
            _msg.Text = Ui.T("Plan con %@ objetos creado. Revísalo en «Sesión automática».", result.Steps.Count);
        }, true);
        _body.Content = Ui.V(Ui.H(Ui.Text(Ui.T("Noche del"), 13), date, Ui.Text(Ui.T("%@ min por objeto", "").Trim(), 13), minutes, use),
            Ui.Caption(Ui.T("Se ordenan para ver cada objeto antes de que se ponga: primero los del oeste al anochecer y al final los que salen por el este al amanecer. Con el Seestar, cada objeto necesita además el tiempo del GoTo.")),
            summary, list);
        _ = Fill();
    }
}
