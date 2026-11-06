using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace Astrolabio.Core.Reports;

/// <summary>
/// PDF A4 de varias páginas con QuestPDF. Astrolabio es gratuito y de código abierto, así que puede
/// usar la licencia Community de QuestPDF sin coste.
/// </summary>
public static class ReportPdf
{
    private const string Blue = "#12336F", LightBlue = "#52A1FF", PaleBlue = "#EDF4FF", Ink = "#1A2133", Muted = "#616E85";

    static ReportPdf()
    {
        QuestPDF.Settings.License = LicenseType.Community;
        QuestPDF.Settings.CheckIfAllTextGlyphsAreAvailable = false;
    }

    public static byte[] Render(ReportDocument doc) => Document.Create(container => container.Page(page =>
    {
        page.Size(PageSizes.A4);
        page.Margin(0);
        page.PageColor(Colors.White);
        page.DefaultTextStyle(x => x.FontSize(9.5f).FontColor(Ink));

        page.Header().Column(h =>
        {
            h.Item().Background(Blue).PaddingVertical(14).PaddingHorizontal(42).Row(row =>
            {
                row.RelativeItem().Column(c =>
                {
                    c.Item().Text(AppVersion.Name).FontSize(18).Bold().FontColor(Colors.White);
                    c.Item().Text(Strings.T("Versión %@", AppVersion.Version)).FontSize(9).FontColor("#C8D8F0");
                });
                row.ConstantItem(220).AlignRight().AlignMiddle().Text(doc.Title).FontSize(11).SemiBold().FontColor(Colors.White);
            });
            h.Item().Height(3).Background(LightBlue);
        });

        page.Content().PaddingHorizontal(42).PaddingTop(22).PaddingBottom(10).Column(col =>
        {
            col.Spacing(4);
            col.Item().Text(doc.Title).FontSize(22).Bold();
            col.Item().PaddingBottom(6).Text(doc.Subtitle).FontSize(13).FontColor(Muted);
            Section(col, Strings.T("Resumen"), doc.Summary);
            Section(col, Strings.T("Condiciones"), doc.Conditions);
            if (doc.Objects.Count > 0)
            {
                Heading(col, Strings.T("Objetos observados"));
                foreach (var o in doc.Objects)
                {
                    col.Item().EnsureSpace(160).PaddingBottom(10).Column(b =>
                    {
                        b.Item().Text(o.Title).FontSize(12).Bold();
                        if (o.Subtitle.Length > 0) b.Item().PaddingBottom(3).Text(o.Subtitle).FontSize(9).FontColor(Muted);
                        b.Item().Row(r =>
                        {
                            r.RelativeItem().Element(e => Table(e, o.Rows));
                            if (o.Image is { } img)
                                r.ConstantItem(184).PaddingLeft(14).MaxHeight(240).Border(0.6f).BorderColor(LightBlue).Image(img).FitArea();
                        });
                    });
                }
            }
            if (doc.Device.Count > 0) Section(col, Strings.T("Telescopio"), doc.Device);
            Heading(col, Strings.T("Eventos y errores"));
            if (doc.Events.Count == 0)
                col.Item().Text(Strings.T("No hay eventos registrados para esta sesión.")).FontColor(Muted);
            else
                foreach (var e in doc.Events) col.Item().Text(e).FontSize(8).FontFamily(Fonts.Consolas);
        });

        page.Footer().PaddingBottom(18).AlignCenter().Text(t =>
        {
            t.DefaultTextStyle(x => x.FontSize(8).FontColor(Muted));
            var parts = Strings.T("Página %d").Split("%d");
            t.Span(doc.Footer + "   ·   " + parts[0]);
            t.CurrentPageNumber();
            if (parts.Length > 1) t.Span(parts[1]);
        });
    })).GeneratePdf();

    private static void Heading(ColumnDescriptor col, string title) =>
        col.Item().PaddingTop(10).PaddingBottom(4).Row(r =>
        {
            r.ConstantItem(3).Background(LightBlue);
            r.RelativeItem().PaddingLeft(6).Text(title).FontSize(13).SemiBold();
        });

    private static void Section(ColumnDescriptor col, string title, List<ReportRow> rows)
    {
        Heading(col, title);
        col.Item().Element(e => Table(e, rows));
    }

    private static void Table(IContainer container, List<ReportRow> rows) => container.Table(t =>
    {
        t.ColumnsDefinition(c => { c.RelativeColumn(42); c.RelativeColumn(58); });
        for (var i = 0; i < rows.Count; i++)
        {
            var bg = i % 2 == 0 ? PaleBlue : Colors.White;
            t.Cell().Background(bg).PaddingVertical(3).PaddingHorizontal(6).Text(rows[i].Label).FontColor(Muted);
            t.Cell().Background(bg).PaddingVertical(3).PaddingHorizontal(6).Text(rows[i].Value);
        }
    });
}
