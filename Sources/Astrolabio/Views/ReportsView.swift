import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Informes: lista de noches de observación y un informe completo de cada una, descargable en PDF.
@MainActor
struct ReportsView: View {
    @EnvironmentObject var history: ObservationLog
    @EnvironmentObject var settings: AppSettings
    @State private var selection: Date?
    @State private var weather: [Date: [WeatherHour]] = [:]
    @State private var images: [UUID: CGImage] = [:]
    @State private var loading = false

    private var nights: [NightSession] { NightSession.group(history.allRecords) }
    private var selected: NightSession? { nights.first { $0.night == selection } ?? nights.first }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 300)
            Divider().overlay(Theme.cardStroke)
            if let s = selected {
                ReportDetail(doc: document(for: s), loading: loading, onPDF: { savePDF(s) })
                    .id(s.night)
                    .task(id: s.night) { await load(s) }
            } else {
                ContentUnavailableView(tr("Todavía no hay sesiones"),
                                       systemImage: "doc.richtext",
                                       description: Text(tr("Cuando apiles con el Seestar, o importes el álbum en Estadísticas, las sesiones aparecerán aquí.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(tr("Sesiones"), systemImage: "list.bullet.rectangle").font(.headline)
                Spacer()
                Text("\(nights.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(12)
            List(nights, selection: Binding(get: { selected?.night }, set: { selection = $0 })) { n in
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.night.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Loc.shared.locale)))
                        .font(.callout.weight(.semibold))
                    Text(n.targets.joined(separator: ", ")).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Label(ReportFormat.duration(n.integrationMinutes), systemImage: "clock")
                        Label(tr("%d fotogramas", n.frames), systemImage: "square.stack.3d.up")
                    }
                    .font(.caption2).foregroundStyle(Theme.accentSoft)
                }
                .padding(.vertical, 3)
                .tag(n.night)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func document(for s: NightSession) -> ReportDocument {
        ReportDocument.make(s, weather: weather[s.night] ?? [], images: images,
                            site: (settings.siteName, settings.latitude, settings.longitude))
    }

    /// Carga las imágenes guardadas (o las del álbum del Seestar) y el tiempo de esa noche si no se guardó.
    private func load(_ s: NightSession) async {
        loading = true
        defer { loading = false }
        for r in s.records where images[r.id] == nil {
            if let url = r.imageURL, let img = CGImage.load(url) { images[r.id] = img; continue }
            if let thumb = r.albumThumb, let url = URL(string: thumb), url.scheme == "http", NetPolicy.isLocal(url.host ?? "") {
                var req = URLRequest(url: url); req.timeoutInterval = 4
                if let (data, _) = try? await URLSession.shared.data(for: req), let img = CGImage.load(data) { images[r.id] = img }
            }
        }
        if weather[s.night] == nil, !s.records.contains(where: { $0.weather != nil }) {
            let lat = s.latitude ?? settings.latitude, lon = s.longitude ?? settings.longitude
            if let hours = try? await WeatherService.history(lat: lat, lon: lon, from: s.start.addingTimeInterval(-86400 / 2),
                                                             to: min(s.end.addingTimeInterval(86400 / 2), Date())) {
                weather[s.night] = hours
            }
        }
    }

    private func savePDF(_ s: NightSession) {
        let data = ReportPDF.render(document(for: s))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "\(AppInfo.name)-\(tr("Informe"))-\(f.string(from: s.night)).pdf"
        panel.directoryURL = settings.saveFolderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let a = NSAlert(); a.messageText = tr("No se pudo guardar el PDF"); a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}

/// Informe en pantalla.
@MainActor
struct ReportDetail: View {
    let doc: ReportDocument
    let loading: Bool
    let onPDF: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.title).font(.title2.weight(.bold))
                        Text(doc.subtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button(action: onPDF) { Label(tr("Descargar PDF"), systemImage: "arrow.down.doc") }
                        .buttonStyle(.borderedProminent)
                }
                HStack(alignment: .top, spacing: 14) {
                    Card(title: tr("Resumen"), systemImage: "calendar") { rows(doc.summary) }
                    Card(title: tr("Condiciones"), systemImage: "cloud.moon") { rows(doc.conditions) }
                }
                Text(tr("Objetos observados")).font(.headline)
                ForEach(Array(doc.objects.enumerated()), id: \.offset) { _, o in
                    Card(title: o.title, systemImage: "scope") {
                        if !o.subtitle.isEmpty { Text(o.subtitle).font(.caption).foregroundStyle(.secondary) }
                        HStack(alignment: .top, spacing: 14) {
                            rows(o.rows)
                            if let img = o.image {
                                Image(decorative: img, scale: 1).resizable().scaledToFit()
                                    .frame(maxWidth: 260, maxHeight: 260)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke))
                            }
                        }
                    }
                }
                if !doc.device.isEmpty {
                    Card(title: tr("Telescopio"), systemImage: "battery.75percent") { rows(doc.device) }
                }
                Card(title: tr("Eventos y errores"), systemImage: "exclamationmark.bubble") {
                    if doc.events.isEmpty {
                        Text(tr("No hay eventos registrados para esta sesión.")).foregroundStyle(.secondary).font(.callout)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(doc.events.enumerated()), id: \.offset) { _, e in
                                Text(e).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }
                Text(doc.footer).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func rows(_ r: [ReportDocument.Row]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(r, id: \.self) { InfoRow(label: $0.label, value: $0.value) }
        }
        .frame(maxWidth: .infinity)
    }
}
