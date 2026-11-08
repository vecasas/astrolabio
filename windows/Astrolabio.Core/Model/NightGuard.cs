using Astrolabio.Core.Protocol;
using Astrolabio.Core.Services;

namespace Astrolabio.Core.Model;

/// <summary>Vigilancia de la noche: nitidez de las estrellas, rocío, avisos oficiales y tormentas (igual que NightGuard.swift).</summary>
public sealed class NightGuard(SeestarClient client, AppSettings settings, Func<IReadOnlyList<WeatherHour>> weather) : Observable
{
    private readonly FocusWatch _watch = new();
    private readonly AlertLimiter _limiter = new(TimeSpan.FromMinutes(30));
    private bool _heaterOn;
    private DateTime _lastFetch = DateTime.MinValue;

    private FocusWatch.Verdict _verdict = new FocusWatch.Verdict.Learning();
    public FocusWatch.Verdict FocusVerdict { get => _verdict; private set => Set(ref _verdict, value); }
    private double? _hfr; public double? LastHfr { get => _hfr; private set => Set(ref _hfr, value); }
    private DewRisk _dew; public DewRisk DewRisk { get => _dew; private set => Set(ref _dew, value); }
    private List<WeatherWarning> _warnings = []; public List<WeatherWarning> Warnings { get => _warnings; private set => Set(ref _warnings, value); }
    private string? _storm; public string? StormReason { get => _storm; private set => Set(ref _storm, value); }

    public bool NeedsRefocus => FocusVerdict is FocusWatch.Verdict.Softening;

    public void Handle(StarMetrics.Result m)
    {
        if (!settings.FocusWatch) return;
        LastHfr = m.Hfr;
        _watch.Threshold = settings.FocusThresholdPercent / 100;
        var target = client.ViewTarget ?? "";
        FocusVerdict = _watch.Add(m.Hfr, target);
        if (FocusVerdict is FocusWatch.Verdict.Softening s && _limiter.ShouldSend("focus", DateTime.Now))
        {
            var text = Strings.T("⚠️ Las estrellas están un %@ %% menos nítidas que al empezar %@: revisa el enfoque o el rocío.", s.Percent, target);
            if (DewRisk != DewRisk.Low) text += " " + Strings.T("Hay riesgo de rocío: enciende el calentador.");
            client.AddLog(text, LogLevel.Warning);
            settings.Notify("Astrolabio", text);
        }
    }

    public void Refocused() { _watch.Reset(client.ViewTarget ?? ""); FocusVerdict = new FocusWatch.Verdict.Learning(); }

    /// <summary>Cada minuto.</summary>
    public async Task Tick()
    {
        var hours = weather();
        if (WeatherService.Nearest(DateTime.UtcNow, hours) is { } h)
        {
            DewRisk = Dew.Level(h.Temperature, h.DewPoint);
            if (DewRisk == DewRisk.High && client.IsConnected)
            {
                if (settings.AutoDewHeater && !_heaterOn)
                {
                    var power = settings.DewHeaterPower > 0 ? settings.DewHeaterPower : 60;
                    try { await client.SetDewHeater(power); _heaterOn = true; client.AddLog(Strings.T("Riesgo alto de rocío: calentador encendido al %@ %%.", power)); } catch { }
                }
                else if (!settings.AutoDewHeater && _limiter.ShouldSend("dew", DateTime.Now))
                {
                    var text = Strings.T("💧 Riesgo alto de rocío (%@ °C, punto de rocío %@ °C). Enciende el calentador del Seestar.", (int)Math.Round(h.Temperature), (int)Math.Round(h.DewPoint));
                    client.AddLog(text, LogLevel.Warning);
                    settings.Notify("Astrolabio", text);
                }
            }
        }
        if ((DateTime.Now - _lastFetch).TotalMinutes > 15)
        {
            _lastFetch = DateTime.Now;
            try
            {
                var all = await MeteoAlarm.Fetch(settings.AlertCountry);
                Warnings = settings.AlertZone.Length == 0 ? [] : all.Where(w => w.Area == settings.AlertZone).ToList();
            }
            catch { }
        }
        var reason = settings.StormGuard ? StormGuard.Reason(Warnings, hours, DateTime.UtcNow) : null;
        if (reason != StormReason)
        {
            StormReason = reason;
            if (reason is not null && _limiter.ShouldSend("storm", DateTime.Now))
            {
                client.AddLog("⛈ " + reason, LogLevel.Warning);
                settings.Notify("Astrolabio", "⛈ " + reason);
            }
        }
    }
}
