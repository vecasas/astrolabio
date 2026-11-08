using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Model;
using Astrolabio.Core.Services;

namespace Astrolabio.App.Views;

/// <summary>«Qué mirar»: los mejores objetos de la noche con foto, descripción y recomendación.</summary>
public sealed class TonightView : UserControl
{
    private readonly MainWindow _main;
    private readonly WrapPanel _cards = new();
    private readonly StackPanel _summary = new() { Orientation = Orientation.Horizontal, Spacing = 14 };
    private string _filter = "Todo";
    private bool _onlyNow;
    private readonly TextBlock _msg = Ui.Caption("");

    public TonightView(MainWindow main)
    {
        _main = main;
        var st = AppState.Instance;
        var filters = Ui.H();
        foreach (var f in new[] { "Todo", "Galaxias", "Nebulosas", "Cúmulos", "Planetarias" })
            filters.Children.Add(Ui.Button(Ui.T(f), () => { _filter = f; Fill(); }));
        var onlyNow = new CheckBox { Content = Ui.T("Solo lo que está alto ahora") };
        onlyNow.IsCheckedChanged += (_, _) => { _onlyNow = onlyNow.IsChecked == true; Fill(); };
        Content = Ui.Scroll(Ui.V(_summary, Ui.Wrap(new WeekOutlookCard { Width = 420 }, new CometsTonightCard(_msg) { Width = 560 }), Ui.H(filters, onlyNow, Ui.Button(Ui.T("Recalcular"), async () => await st.RecomputeTonight())), _msg, _cards));
        st.TonightUpdated += () => Avalonia.Threading.Dispatcher.UIThread.Post(Fill);
        Fill();
        if (st.Forecasts.Count == 0) _ = st.RecomputeTonight();
    }

    private bool Matches(ObjectKind k) => _filter switch
    {
        "Galaxias" => k == ObjectKind.Galaxy, "Nebulosas" => k is ObjectKind.Nebula or ObjectKind.Snr,
        "Cúmulos" => k is ObjectKind.Open or ObjectKind.Globular, "Planetarias" => k == ObjectKind.Planetary, _ => true,
    };

    private void Fill()
    {
        var st = AppState.Instance; var s = st.Settings;
        _summary.Children.Clear();
        var q = PickForMe.NightQuality(st.Night, st.Weather);
        _summary.Children.Add(Ui.Tile(Ui.T("Calidad de la noche"), q is { } qq ? $"{qq.Score:F0}" : "—",
            q is { } q2 ? Ui.T(q2.Score >= 70 ? "Excelente para cielo profundo" : q2.Score >= 45 ? "Buena noche" : q2.Score >= 25 ? "Regular: mejor objetos brillantes" : "Poco aprovechable") : null));
        _summary.Children.Add(Ui.Tile(Ui.T("Noche cerrada"), $"{Ui.Time(st.Night?.DuskStart)} – {Ui.Time(st.Night?.DawnEnd)}",
            Ui.T("Puesta de Sol %@ · salida %@", Ui.Time(st.Night?.Sunset), Ui.Time(st.Night?.Sunrise))));
        _summary.Children.Add(Ui.Tile(Ui.T("Luna"), q is { } q3 ? $"{q3.MoonFactor * 100:F0} %" : "—", Astro.MoonPhase(DateTime.UtcNow).Name));
        _summary.Children.Add(Ui.Tile(Ui.T("Nubes en la noche"), q?.Cloud is double cl ? $"{cl:F0} %" : "—", Ui.T("Previsión de Open-Meteo")));

        _cards.Children.Clear();
        var list = st.Forecasts.Where(f => f.Score > 0 && Matches(f.Object.Kind))
            .Where(f => !_onlyNow || Ephemeris.FixedAltitude(f.Object.RaHours, f.Object.DecDeg, s.Latitude, s.Longitude)(DateTime.UtcNow) >= s.MinAltitude)
            .Take(24).ToList();
        if (list.Count == 0) _cards.Children.Add(Ui.Caption(st.Forecasts.Count == 0 ? Ui.T("Calculando la noche…") : Ui.T("Ningún objeto cumple el filtro ahora mismo.")));
        for (var i = 0; i < list.Count; i++) _cards.Children.Add(Card(i + 1, list[i]));
    }

    private Control Card(int rank, TargetForecast f)
    {
        var st = AppState.Instance; var s = st.Settings; var o = f.Object;
        var altNow = Ephemeris.FixedAltitude(o.RaHours, o.DecDeg, s.Latitude, s.Longitude)(DateTime.UtcNow);
        var desc = Ui.Text(Ui.T("Cargando descripción…"), 11, color: Ui.Secondary, wrap: true);
        desc.MaxHeight = 64;
        _ = LoadDesc(o, desc);
        var go = Ui.Button(Ui.T("Ir y apilar…"), async () => await new GotoConfirmWindow(o, m => _msg.Text = m).ShowDialog(_main), true);
        go.IsEnabled = st.Client.IsConnected && altNow >= s.MinAltitude;
        var right = Ui.V(
            Ui.H(Ui.Text($"{rank}", 18, FontWeight.Bold, Ui.Accent), Ui.V(Ui.Text(o.Id, 15, FontWeight.SemiBold), Ui.Caption(o.Name.Length == 0 ? o.Kind.Label() : o.LocalizedName, false)),
                 Ui.Pill($"★ {f.Score:F0}", f.Score > 50 ? Ui.Good : Ui.AccentSoft)),
            Ui.H(Ui.Pill(o.Kind.Label()), Ui.Pill(f.Fit.Label, Ui.AccentSoft)),
            Ui.Caption(Ui.T("Magnitud %.1f · tamaño %.0f′", o.Magnitude, o.SizeArcmin)), desc,
            Ui.Caption($"{Ui.T("Ahora")} {altNow:F0}° · {Ui.T("Mejor")} {Ui.Time(f.BestTime)} · {Ui.T("Útil")} {f.MinutesUsable / 60:F1} h · {Ui.T("Luna")} {f.MoonSeparation:F0}°"),
            Advice.Summary(o),
            Ui.H(go, Ui.Button(Ui.T("Al plan"), () => { st.Plan.Add(o, Math.Min(120, Math.Max(30, Math.Round(f.MinutesUsable * 0.5 / 15) * 15)), f.Fit); _msg.Text = Ui.T("%@ añadido al plan de la noche.", o.Id); })));
        right.Width = 270;
        return new Border
        {
            Width = 420, Margin = new Thickness(0, 0, 14, 14), Padding = new Thickness(12), CornerRadius = new CornerRadius(14),
            Background = Ui.CardBg, BorderBrush = Ui.CardStroke, BorderThickness = new Thickness(1),
            Child = Ui.H(new SkyImage(o.RaHours, o.DecDeg, o.SizeArcmin, s.FovWidthDeg, s.FovHeightDeg, 104), right),
        };
    }

    private static async Task LoadDesc(DeepSkyObject o, TextBlock t)
    {
        var r = await WikipediaService.Summary(o);
        t.Text = r?.Extract ?? Ui.T("Sin descripción disponible.");
        if (r?.Url is string url) ToolTip.SetTip(t, r.Value.Extract);
    }
}

/// <summary>«Elige por mí»: propone un objeto concreto (o un plan corto) listo para lanzar.</summary>
public sealed class PickView : UserControl
{
    private readonly MainWindow _main;
    private PickStyle _style = PickStyle.Best;
    private int _index;
    private List<Suggestion> _list = [];
    private readonly ContentControl _hero = new();
    private readonly ContentControl _plan = new();
    private readonly TextBlock _msg = Ui.Caption("");

    public PickView(MainWindow main)
    {
        _main = main;
        var styles = Ui.H();
        foreach (var s in Enum.GetValues<PickStyle>()) styles.Children.Add(Ui.Button(Ui.T(s.Key()), () => { _style = s; _index = 0; Recompute(); }, s == _style));
        Content = Ui.Scroll(Ui.V(styles, _hero, _msg, _plan));
        AppState.Instance.TonightUpdated += () => Avalonia.Threading.Dispatcher.UIThread.Post(Recompute);
        Recompute();
    }

    private void Recompute()
    {
        var st = AppState.Instance; var s = st.Settings;
        _list = PickForMe.Suggestions(st.Forecasts, st.Night, _style, s.Latitude, s.Longitude, s.MinAltitude);
        _hero.Content = _list.Count == 0
            ? Ui.Card(Ui.T("Sin sugerencias"), Ui.Caption(st.Forecasts.Count == 0 ? Ui.T("Calculando la noche…") : Ui.T("Ahora mismo no hay ningún objeto de este tipo lo bastante alto durante al menos 40 minutos. Prueba otro estilo o baja la altura mínima en Ajustes.")))
            : Hero(_list[_index % _list.Count]);
        var plan = PickForMe.ShortPlan(st.Forecasts, st.Night, s.Latitude, s.Longitude, s.MinAltitude);
        var rows = plan.Select((p, i) => (Control)Ui.Text($"{i + 1}. {Catalog.Find(p.Name)?.DisplayName ?? p.Name} · {(p.NotBefore is DateTime nb ? Ui.T("desde las %@", nb.ToLocalTime().ToString("t", Strings.Culture)) : Ui.T("Ahora"))} · {p.Minutes:F0} min{(p.LpFilter ? " · LP" : "")}", 13)).ToList();
        if (plan.Count > 0) rows.Add(Ui.Button(Ui.T("Añadir al plan y abrir Sesión automática"), () => { st.Plan.Items.AddRange(plan); st.Plan.Save(); _main.Navigate(Section.Session); }, true));
        else rows.Add(Ui.Caption(Ui.T("No queda suficiente noche para un plan (o aún se está calculando).")));
        _plan.Content = Ui.Card(Ui.T("O deja que planifique el resto de la noche"), rows.ToArray());
    }

    private Control Hero(Suggestion sug)
    {
        var st = AppState.Instance; var s = st.Settings; var o = sug.Forecast.Object;
        var adv = CaptureAdvice.Make(o, s.Latitude, s.Longitude, s.MinAltitude, st.Night, st.Client.CurrentGain ?? s.Gain, sug.Start);
        var later = sug.Start > DateTime.UtcNow.AddMinutes(2);
        var go = Ui.Button(Ui.T("Apuntar y apilar…"), async () => await new GotoConfirmWindow(o, m => _msg.Text = m).ShowDialog(_main), true);
        go.IsEnabled = st.Client.IsConnected && !later;
        var header = Ui.V(
            Ui.Caption(later ? Ui.T("Cuando oscurezca (%@) te propongo…", Ui.Time(sug.Start)) : Ui.T("Te propongo…"), false),
            Ui.Text(o.Id, 32, FontWeight.Bold), o.Name.Length > 0 ? Ui.Text(o.LocalizedName, 18, color: Ui.AccentSoft) : new Control(),
            Ui.H(Ui.Pill(o.Kind.Label()), Ui.Pill(Ui.T("Nota %.0f", sug.Forecast.Score), Ui.Good), Ui.Pill($"mag {o.Magnitude:F1} · {o.SizeArcmin:F0}′", Ui.Secondary)),
            Ui.Text(Ui.T("Por qué"), 14, FontWeight.SemiBold),
            Ui.V(sug.Reasons.Select(r => (Control)Ui.Text("✓ " + r, 13, wrap: true)).ToArray()));
        return new Border
        {
            Background = Ui.CardBg, BorderBrush = Ui.Accent, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(18), Padding = new Thickness(20),
            Child = Ui.V(
                Ui.H(new SkyImage(o.RaHours, o.DecDeg, o.SizeArcmin, s.FovWidthDeg, s.FovHeightDeg, 170), header),
                Ui.H(Ui.Tile(Ui.T("Duración sugerida"), $"{adv.Minutes:F0} min"), Ui.Tile(Ui.T("Exposición"), $"{adv.ExposureMs / 1000} s", Ui.T("Ganancia %@", adv.Gain)),
                     Ui.Tile(Ui.T("Filtro LP"), adv.LpFilter ? Ui.T("Sí") : Ui.T("No"))),
                Ui.H(go, Ui.Button(Ui.T("Otra sugerencia"), () => { _index++; _hero.Content = Hero(_list[_index % _list.Count]); }),
                     Ui.Button(Ui.T("Al plan"), () => { st.Plan.Items.Add(new PlanItem { Name = o.Id, RaHours = o.RaHours, DecDeg = o.DecDeg, Minutes = adv.Minutes, LpFilter = adv.LpFilter }); st.Plan.Save(); _msg.Text = Ui.T("%@ añadido al plan.", o.Id); }),
                     Ui.Caption(Ui.T("%@ de %@", _index % _list.Count + 1, _list.Count), false))),
        };
    }
}
