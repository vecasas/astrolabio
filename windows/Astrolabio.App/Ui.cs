using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Astrolabio.Core;

namespace Astrolabio.App;

/// <summary>Colores y piezas comunes de la interfaz (mismo tema azul que en macOS).</summary>
public static class Ui
{
    public static readonly Color AccentColor = Color.FromRgb(82, 161, 255);
    public static readonly IBrush Accent = new SolidColorBrush(AccentColor);
    public static readonly IBrush AccentSoft = new SolidColorBrush(Color.FromRgb(140, 199, 255));
    public static readonly IBrush Deep = new SolidColorBrush(Color.FromRgb(5, 13, 31));
    public static readonly IBrush Navy = new SolidColorBrush(Color.FromRgb(13, 27, 57));
    public static readonly IBrush CardBg = new SolidColorBrush(Color.FromArgb(200, 22, 40, 77));
    public static readonly IBrush CardStroke = new SolidColorBrush(Color.FromArgb(56, 102, 153, 255));
    public static readonly IBrush Good = new SolidColorBrush(Color.FromRgb(89, 217, 191));
    public static readonly IBrush Warn = new SolidColorBrush(Color.FromRgb(255, 184, 89));
    public static readonly IBrush Bad = new SolidColorBrush(Color.FromRgb(255, 115, 115));
    public static readonly IBrush Secondary = new SolidColorBrush(Color.FromArgb(170, 235, 240, 255));
    public static readonly IBrush Background = new LinearGradientBrush
    {
        StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.FromRgb(5, 13, 31), 0), new GradientStop(Color.FromRgb(13, 27, 57), 1) },
    };

    public static string T(string key) => Strings.T(key);
    public static string T(string key, params object?[] args) => Strings.T(key, args);

    public static TextBlock Text(string s, double size = 13, FontWeight weight = FontWeight.Normal, IBrush? color = null, bool wrap = false) =>
        new() { Text = s, FontSize = size, FontWeight = weight, Foreground = color ?? Brushes.White, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap };

    public static TextBlock Caption(string s, bool wrap = true) => Text(s, 11, color: Secondary, wrap: wrap);

    public static Button Button(string s, Action onClick, bool primary = false)
    {
        var b = new Button { Content = s, Padding = new Thickness(12, 5) };
        if (primary) b.Classes.Add("accent");
        b.Click += (_, _) => onClick();
        return b;
    }

    public static Border Card(string title, params Control[] children)
    {
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(Text(title, 15, FontWeight.SemiBold));
        foreach (var c in children) stack.Children.Add(c);
        return new Border { Background = CardBg, BorderBrush = CardStroke, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Padding = new Thickness(14), Child = stack };
    }

    public static Border Tile(string title, string value, string? detail = null)
    {
        var s = new StackPanel { Spacing = 3 };
        s.Children.Add(Caption(title, false));
        s.Children.Add(Text(value, 24, FontWeight.SemiBold, AccentSoft));
        if (detail is not null) s.Children.Add(Caption(detail));
        return new Border { Background = CardBg, BorderBrush = CardStroke, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Padding = new Thickness(14), Child = s, MinWidth = 150 };
    }

    public static Border Pill(string s, IBrush? color = null)
    {
        var c = color ?? Accent;
        return new Border
        {
            Child = Text(s, 11, FontWeight.SemiBold, c), Padding = new Thickness(8, 2), CornerRadius = new CornerRadius(10),
            BorderBrush = c, BorderThickness = new Thickness(0.5), Background = new SolidColorBrush(Color.FromArgb(40, 82, 161, 255)),
        };
    }

    public static Grid Row(string label, Control value)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        g.Children.Add(Text(label, 12, color: Secondary));
        Grid.SetColumn(value, 1);
        g.Children.Add(value);
        return g;
    }

    public static Grid Row(string label, string value) => Row(label, Text(value, 12));

    public static StackPanel H(params Control[] c) { var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; foreach (var x in c) s.Children.Add(x); return s; }
    public static StackPanel V(params Control[] c) { var s = new StackPanel { Spacing = 10 }; foreach (var x in c) s.Children.Add(x); return s; }

    public static ScrollViewer Scroll(Control c) => new() { Content = new Border { Padding = new Thickness(20), Child = c }, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };

    public static WrapPanel Wrap(params Control[] c) { var w = new WrapPanel(); foreach (var x in c) { x.Margin = new Thickness(0, 0, 14, 14); w.Children.Add(x); } return w; }

    public static string Time(DateTime? utc) => utc is DateTime t ? t.ToLocalTime().ToString("t", Strings.Culture) : "—";

    public static async Task Run(string label, Func<Task> op)
    {
        var c = AppState.Instance.Client;
        try { await op(); c.AddLog(T("%@: hecho.", label)); }
        catch (Exception e) { c.AddLog($"{label}: {e.Message}", Core.Protocol.LogLevel.Error); await MessageBox.Show(label, e.Message); }
    }
}

/// <summary>Diálogo sencillo de aviso.</summary>
public static class MessageBox
{
    public static async Task Show(string title, string message)
    {
        var owner = (Avalonia.Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.MainWindow;
        var w = new Window { Title = title, Width = 420, SizeToContent = SizeToContent.Height, Background = Ui.Navy, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var ok = Ui.Button("OK", () => w.Close(), true);
        ok.HorizontalAlignment = HorizontalAlignment.Right;
        w.Content = new StackPanel { Margin = new Thickness(20), Spacing = 14, Children = { Ui.Text(title, 15, FontWeight.SemiBold), Ui.Text(message, wrap: true), ok } };
        if (owner is not null) await w.ShowDialog(owner); else w.Show();
    }

    public static async Task<bool> Confirm(string title, string message, string accept)
    {
        var owner = (Avalonia.Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.MainWindow;
        var result = false;
        var w = new Window { Title = title, Width = 420, SizeToContent = SizeToContent.Height, Background = Ui.Navy, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var buttons = Ui.H(Ui.Button(Ui.T("Cancelar"), () => w.Close()), Ui.Button(accept, () => { result = true; w.Close(); }, true));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        w.Content = new StackPanel { Margin = new Thickness(20), Spacing = 14, Children = { Ui.Text(title, 15, FontWeight.SemiBold), Ui.Text(message, wrap: true), buttons } };
        if (owner is not null) await w.ShowDialog(owner);
        return result;
    }
}
