using System.Collections.ObjectModel;
using System.Text.Json;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Protocol;
using Astrolabio.Core.Services;

namespace Astrolabio.Core.Model;

/// <summary>
/// Ejecuta el plan sin vigilancia: espera a la noche, apunta, enfoca, apila el tiempo pedido, pasa
/// al siguiente, se pausa si se prevén nubes y aparca al amanecer (port de Session.swift).
/// </summary>
public sealed class SessionRunner : Observable
{
    public enum RunPhase { Idle, WaitingDark, WaitingTarget, Slewing, Focusing, Stacking, PausedClouds, PausedStorm, Darks, Parking, Finished, Stopped }

    public static string PhaseKey(RunPhase p) => p switch
    {
        RunPhase.Idle => "En espera", RunPhase.WaitingDark => "Esperando a que oscurezca", RunPhase.WaitingTarget => "Esperando a que el objeto suba",
        RunPhase.Slewing => "Apuntando", RunPhase.Focusing => "Enfocando", RunPhase.Stacking => "Apilando", RunPhase.PausedClouds => "En pausa por nubes",
        RunPhase.PausedStorm => "Recogido por mal tiempo", RunPhase.Darks => "Creando oscuros", RunPhase.Parking => "Aparcando", RunPhase.Finished => "Plan terminado", _ => "Detenido",
    };

    private readonly SynchronizationContext? _ui = SynchronizationContext.Current;
    private RunPhase _phase; public RunPhase Phase { get => _phase; private set { if (Set(ref _phase, value)) OnPropertyChanged(nameof(PhaseLabel)); } }
    public string PhaseLabel => Strings.T(PhaseKey(Phase));
    private double _remaining; public double RemainingSeconds { get => _remaining; private set => Set(ref _remaining, value); }
    public ObservableCollection<string> Messages { get; } = new();
    public bool WaitForDark { get; set; } = true;
    public bool PauseForClouds { get; set; } = true;
    public bool StopAtDawn { get; set; } = true;
    public bool IsRunning => _cts is not null;
    /// <summary>Vigilancia de enfoque, rocío y tormentas (la pone la app).</summary>
    public NightGuard? Guard { get; set; }

    private CancellationTokenSource? _cts;
    private volatile bool _skip;
    private List<WeatherHour> _weather = [];
    private DateTime _weatherFetched = DateTime.MinValue;

    private void Ui(Action a) { if (_ui is null) a(); else _ui.Post(_ => a(), null); }

    private void Say(SeestarClient c, string text)
    {
        var line = $"{DateTime.Now:t}  {text}";
        Ui(() => Messages.Add(line));
        c.AddLog(Strings.T("[Sesión] %@", text));
    }

    /// <summary>Lo que se guarda para retomar el plan tras cerrar la app o reiniciar el PC.</summary>
    public sealed record SavedState(DateTime StartedAt, bool WaitForDark, bool PauseForClouds, bool StopAtDawn);

    public static string StatePath { get; set; } = Path.Combine(AppPaths.Data, "runner.json");

    /// <summary>Plan interrumpido que se puede retomar (como mucho 16 horas después de empezar).</summary>
    public static SavedState? PendingResume(DateTime? now = null)
    {
        try
        {
            if (!File.Exists(StatePath)) return null;
            var st = JsonSerializer.Deserialize<SavedState>(File.ReadAllText(StatePath));
            return st is not null && ((now ?? DateTime.UtcNow) - st.StartedAt).TotalHours < 16 ? st : null;
        }
        catch { return null; }
    }

    public static void SaveState(SavedState? st)
    {
        try
        {
            if (st is null) { if (File.Exists(StatePath)) File.Delete(StatePath); }
            else File.WriteAllText(StatePath, JsonSerializer.Serialize(st));
        }
        catch { }
    }

    public void Start(SeestarClient client, AppSettings settings, PlanStore plan, SavedState? resuming = null)
    {
        if (_cts is not null) return;
        Messages.Clear();
        if (resuming is not null) { WaitForDark = resuming.WaitForDark; PauseForClouds = resuming.PauseForClouds; StopAtDawn = resuming.StopAtDawn; }
        foreach (var i in plan.Items.Where(i => i.Status == PlanItem.ItemStatus.Running)) i.Status = PlanItem.ItemStatus.Pending;
        plan.Save();
        SaveState(new SavedState(resuming?.StartedAt ?? DateTime.UtcNow, WaitForDark, PauseForClouds, StopAtDawn));
        if (resuming is not null)
        {
            Say(client, Strings.T("Se retoma el plan interrumpido."));
            settings.Notify("Astrolabio", Strings.T("Se retoma el plan de la noche tras un reinicio."));
        }
        _cts = new CancellationTokenSource();
        OnPropertyChanged(nameof(IsRunning));
        var ct = _cts.Token;
        _ = Task.Run(async () =>
        {
            SeestarClient.Unattended = true;
            try { await Run(client, settings, plan, ct); }
            catch (OperationCanceledException) { }
            Ui(() => { _cts = null; OnPropertyChanged(nameof(IsRunning)); });
        });
    }

    public void Stop(SeestarClient client)
    {
        SaveState(null);
        _cts?.Cancel();
        Say(client, Strings.T("Detenido por el usuario."));
        Ui(() => Phase = RunPhase.Stopped);
        _ = Task.Run(async () => { try { await client.StopStack(); await client.StopView(); } catch { } });
    }

    public void Skip(SeestarClient client) { _skip = true; Say(client, Strings.T("Saltando al siguiente objeto…")); }

    private static bool IsDark(AppSettings s) => Astro.SunAltitude(DateTime.UtcNow, s.Latitude, s.Longitude) < -18;

    private async Task<bool> Cloudy(AppSettings s)
    {
        if (!PauseForClouds) return false;
        if ((DateTime.Now - _weatherFetched).TotalMinutes > 30)
        {
            try { _weather = await WeatherService.Forecast(s.Latitude, s.Longitude); _weatherFetched = DateTime.Now; } catch { }
        }
        return WeatherService.CloudCover(DateTime.UtcNow, _weather) is double c && c > s.MaxCloudCover;
    }

    private void SetPhase(RunPhase p) => Ui(() => Phase = p);

    private async Task Run(SeestarClient c, AppSettings s, PlanStore plan, CancellationToken ct)
    {
        Say(c, Strings.T("Comienza el plan con %@ objetos.", plan.Items.Count(i => i.Status == PlanItem.ItemStatus.Pending)));
        if (!c.IsConnected) { Say(c, Strings.T("El telescopio no está conectado.")); SetPhase(RunPhase.Stopped); return; }
        try { await c.SetTimeAndLocation(s.Latitude, s.Longitude); } catch { }
        if (s.DewHeaterPower > 0) { try { await c.SetDewHeater(s.DewHeaterPower); } catch { } }
        if (WaitForDark && !IsDark(s))
        {
            SetPhase(RunPhase.WaitingDark);
            var n = Astro.NightFor(DateTime.Now, s.Latitude, s.Longitude);
            if (n.DuskStart is DateTime dusk) Say(c, Strings.T("Esperando a la noche astronómica (%@).", dusk.ToLocalTime().ToString("t", Strings.Culture)));
            while (!IsDark(s)) await Task.Delay(60_000, ct);
        }
        var lastFocus = DateTime.MinValue;
        foreach (var item in plan.Items.ToList())
        {
            ct.ThrowIfCancellationRequested();
            if (item.Status != PlanItem.ItemStatus.Pending) continue;
            if (StopAtDawn && WaitForDark && !IsDark(s)) { Say(c, Strings.T("Ha llegado el amanecer.")); break; }
            _skip = false;
            item.Status = PlanItem.ItemStatus.Running; Ui(plan.Save);
            var (ok, lf) = await RunItem(c, s, plan, item, lastFocus, ct);
            lastFocus = lf;
            item.Status = ok ? PlanItem.ItemStatus.Done : _skip ? PlanItem.ItemStatus.Skipped : PlanItem.ItemStatus.Failed;
            Ui(plan.Save);
            if (!ok && !_skip) s.Notify("Astrolabio", Strings.T("No se pudo completar %@.", item.Name));
        }
        SaveState(null);
        try { await c.StopStack(); } catch { }
        if (s.DarksAtEnd)
        {
            SetPhase(RunPhase.Darks);
            Say(c, Strings.T("Creando los oscuros…"));
            Say(c, await c.CreateDarksAndWait() ? Strings.T("Oscuros creados.") : Strings.T("No se pudieron crear los oscuros."));
        }
        switch (s.EndAction)
        {
            case EndAction.Park:
                SetPhase(RunPhase.Parking);
                Say(c, Strings.T("Aparcando el telescopio."));
                try { await c.Park(); } catch { }
                break;
            case EndAction.Shutdown:
                SetPhase(RunPhase.Parking);
                Say(c, Strings.T("Aparcando y apagando el telescopio."));
                try { await c.Park(); await Task.Delay(40_000, ct); await c.Shutdown(); } catch { }
                break;
        }
        SetPhase(RunPhase.Finished);
        Say(c, Strings.T("Plan terminado."));
        s.Notify("Astrolabio", Strings.T("El plan de la noche ha terminado."));
    }

    /// <summary>Recoge el telescopio y espera 30 minutos seguidos sin mal tiempo.</summary>
    private async Task<bool> WaitOutStorm(SeestarClient c, AppSettings s, string reason, CancellationToken ct)
    {
        SetPhase(RunPhase.PausedStorm);
        Say(c, Strings.T("Mal tiempo: %@ Se recoge el telescopio.", reason));
        s.Notify("Astrolabio", Strings.T("⛈ Telescopio recogido: %@", reason));
        try { await c.StopStack(); await c.Park(); } catch { }
        DateTime? calm = null;
        while (true)
        {
            await Task.Delay(60_000, ct);
            if (StopAtDawn && WaitForDark && !IsDark(s)) return false;
            if (Guard?.StormReason is null) { calm ??= DateTime.Now; if ((DateTime.Now - calm.Value).TotalMinutes >= 30) break; }
            else calm = null;
        }
        Say(c, Strings.T("Ha pasado el mal tiempo: se reanuda el plan."));
        s.Notify("Astrolabio", Strings.T("Ha pasado el mal tiempo: se reanuda el plan."));
        return true;
    }

    private async Task<(bool, DateTime)> RunItem(SeestarClient c, AppSettings s, PlanStore plan, PlanItem item, DateTime lastFocus, CancellationToken ct)
    {
        var panels = item.IsMosaic
            ? Planner.MosaicPanels(item.RaHours, item.DecDeg, item.MosaicColumns, item.MosaicRows, item.OverlapPercent, s.Fov)
            : [("", item.RaHours, item.DecDeg)];
        var remainingByPanel = PlanProgress.RemainingPerPanel(item.Minutes * 60, panels.Count, item.DoneSeconds ?? 0);
        var any = (item.DoneSeconds ?? 0) > 0;
        var panelIndex = -1;
        if (item.NotBefore is DateTime nb && nb > DateTime.Now)
        {
            SetPhase(RunPhase.WaitingTarget);
            Say(c, Strings.T("%@: esperando hasta %@.", item.Name, nb.ToString("t", Strings.Culture)));
            while (DateTime.Now < nb) { await Task.Delay(30_000, ct); if (_skip) return (false, lastFocus); }
        }
        foreach (var (plabel, pra, pdec) in panels)
        {
            panelIndex++;
            if (_skip) return (any, lastFocus);
            if (remainingByPanel[panelIndex] < 5) continue;
            var label = plabel.Length == 0 ? item.Name : $"{item.Name}_{plabel}";
            var now = Astro.PrecessFromJ2000(pra, pdec, DateTime.UtcNow);
            double AltAt(DateTime t) => Astro.AltAz(now.Ra, now.Dec, t, s.Latitude, s.Longitude).Alt;
            var alt = AltAt(DateTime.UtcNow);
            if (alt < s.MinAltitude)
            {
                var rising = Enumerable.Range(1, 9).Any(k => { var t = DateTime.UtcNow.AddMinutes(10 * k); return AltAt(t) >= s.MinAltitude && Astro.SunAltitude(t, s.Latitude, s.Longitude) < -18; });
                if (!rising) { Say(c, Strings.T("%@ está demasiado bajo (%@°). Se salta.", label, (int)alt)); continue; }
                SetPhase(RunPhase.WaitingTarget);
                Say(c, Strings.T("%@ está a %@°; esperando a que suba.", label, (int)alt));
                while (alt < s.MinAltitude) { await Task.Delay(60_000, ct); if (_skip) return (any, lastFocus); alt = AltAt(DateTime.UtcNow); }
            }
            var remaining = remainingByPanel[panelIndex];
            var needGoto = true;
            while (remaining > 5)
            {
                if (_skip) return (any, lastFocus);
                if (Guard?.StormReason is string storm)
                {
                    if (!await WaitOutStorm(c, s, storm, ct)) return (any, lastFocus);
                    needGoto = true;
                    continue;
                }
                if (await Cloudy(s))
                {
                    SetPhase(RunPhase.PausedClouds);
                    Say(c, Strings.T("Se prevén nubes. Pausa de 10 minutos."));
                    s.Notify("Astrolabio", Strings.T("Sesión en pausa por nubes."));
                    try { await c.StopStack(); } catch { }
                    await Task.Delay(600_000, ct);
                    needGoto = true;
                    continue;
                }
                if (needGoto)
                {
                    SetPhase(RunPhase.Slewing);
                    Say(c, Strings.T("Apuntando a %@…", label));
                    var target = Astro.PrecessFromJ2000(pra, pdec, DateTime.UtcNow);
                    var reached = false;
                    for (var attempt = 1; attempt <= 3 && !reached; attempt++)
                    {
                        try { reached = await c.GotoAndWait(label, target.Ra, target.Dec, item.LpFilter); }
                        catch (Exception e) { Say(c, Strings.T("Error en el GoTo: %@", e.Message)); }
                        if (reached || _skip) break;
                        Say(c, Strings.T("GoTo fallido (intento %@). Reintento en 30 s.", attempt));
                        await Task.Delay(30_000, ct);
                    }
                    if (!reached) { Say(c, Strings.T("No se pudo alcanzar %@.", label)); break; }
                    needGoto = false;
                    if (item.Autofocus && ((DateTime.Now - lastFocus).TotalHours > 1 || Guard?.NeedsRefocus == true))
                    {
                        SetPhase(RunPhase.Focusing);
                        Say(c, Strings.T("Enfoque automático…"));
                        if (await c.AutoFocusAndWait(2)) { lastFocus = DateTime.Now; Guard?.Refocused(); } else Say(c, Strings.T("El enfoque falló; se sigue con el enfoque actual."));
                    }
                    try { await c.SetLPFilter(item.LpFilter); await c.SetTargetName(label); await c.SetGain(s.Gain); } catch { }
                    try { await c.StartStack(); }
                    catch (Exception e) { Say(c, Strings.T("No se pudo empezar a apilar: %@", e.Message)); break; }
                    SetPhase(RunPhase.Stacking);
                    Say(c, Strings.T("Apilando %@ durante %@ min.", label, (int)(remaining / 60)));
                }
                var chunkEnd = DateTime.Now.AddSeconds(Math.Min(remaining, 300));
                while (DateTime.Now < chunkEnd)
                {
                    try { await Task.Delay(5000, ct); }
                    catch { try { await c.StopStack(); } catch { } throw; }
                    if (_skip) { try { await c.StopStack(); } catch { } return (any, lastFocus); }
                    if (Guard?.StormReason is not null) break;
                    remaining -= 5;
                    var r = remaining; Ui(() => RemainingSeconds = r);
                    item.StackedFrames = c.StackedFrames;
                    item.DoneSeconds = (item.DoneSeconds ?? 0) + 5;
                    if ((int)remaining % 60 == 0) Ui(plan.Save);
                }
                any = true;
                if (Guard?.StormReason is not null) continue;
                if (s.AutoRefocus && item.Autofocus && Guard?.NeedsRefocus == true && remaining > 300)
                {
                    Say(c, Strings.T("Las estrellas han perdido nitidez: se vuelve a enfocar."));
                    try { await c.StopStack(); } catch { }
                    SetPhase(RunPhase.Focusing);
                    if (await c.AutoFocusAndWait(2)) { lastFocus = DateTime.Now; Guard?.Refocused(); }
                    try { await c.StartStack(); } catch { }
                    SetPhase(RunPhase.Stacking);
                }
                if (StopAtDawn && !IsDark(s)) { Say(c, Strings.T("Amanece: fin del apilado.")); try { await c.StopStack(); } catch { } return (true, lastFocus); }
                var altNow = AltAt(DateTime.UtcNow);
                if (altNow < s.MinAltitude - 5) { Say(c, Strings.T("%@ ha bajado a %@°. Siguiente.", label, (int)altNow)); break; }
            }
            try { await c.StopStack(); } catch { }
            Say(c, Strings.T("Terminado %@.", label));
        }
        return (any, lastFocus);
    }
}
