using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml.Styling;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
using Astrolabio.Core;

namespace Astrolabio.App;

public sealed class App : Application
{
    public override void Initialize()
    {
        RequestedThemeVariant = ThemeVariant.Dark;
        Styles.Add(new FluentTheme());
        Resources["SystemAccentColor"] = Ui.AccentColor;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        var state = AppState.Instance;
        if (state.Settings.Language is string l && Enum.TryParse<AppLanguage>(l, out var lang)) Strings.SetLanguage(lang);
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            desktop.MainWindow = new MainWindow();
        base.OnFrameworkInitializationCompleted();
    }
}
