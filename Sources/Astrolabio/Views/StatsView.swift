import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Estadísticas de observación a partir del historial que guarda Astrolabio.
@MainActor
struct StatsView: View {
    @EnvironmentObject var history: ObservationLog
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: SeestarClient
    @State private var importing = false

    enum Range: String, CaseIterable, Identifiable {
        case month = "30 días", year = "12 meses", all = "Todo"
        var id: String { rawValue }
        var start: Date? {
            switch self {
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .year: return Calendar.current.date(byAdding: .month, value: -12, to: Date())
            case .all: return nil
            }
        }
    }

    @State private var range: Range = .all
    @State private var selection = Set<ObservationRecord.ID>()
    @State private var message = ""

    private var records: [ObservationRecord] {
        history.allRecords.filter { r in range.start.map { r.start >= $0 } ?? true }.sorted { $0.start > $1.start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("", selection: $range) { ForEach(Range.allCases) { Text(tr($0.rawValue)).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 300)
                    Spacer()
                    if let cur = history.current {
                        Pill(text: tr("Grabando: %@ · %@ fotogramas", "\(cur.target)", "\(cur.frames)"), systemImage: "record.circle", color: Theme.good)
                    }
                    Button { importAlbum() } label: { Label(tr("Importar del Seestar"), systemImage: "square.and.arrow.down") }
                        .disabled(!client.isConnected || importing)
                        .help(tr("Añade las sesiones guardadas en el álbum del telescopio (aunque se hicieran con otra app)."))
                    Button { exportCSV() } label: { Label(tr("Exportar CSV"), systemImage: "square.and.arrow.up") }
                        .disabled(records.isEmpty)
                }
                if records.isEmpty {
                    empty
                } else {
                    tiles
                    HStack(alignment: .top, spacing: 14) {
                        perNightChart.frame(maxWidth: .infinity)
                        perKindChart.frame(width: 340)
                    }
                    objectsTable
                    sessionsTable
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Theme.accentSoft) }
            }
            .padding(20)
        }
        .navigationTitle(tr("Estadísticas"))
    }

    private var empty: some View {
        Card(title: tr("Aún no hay sesiones"), systemImage: "chart.bar") {
            Text(tr("Astrolabio anota cada sesión de apilado mientras está conectado al Seestar: el objeto, la hora, los fotogramas y el tiempo de integración. Cuando apiles algo, aparecerá aquí. También puedes traer las sesiones anteriores con «Importar del Seestar»."))
                .foregroundStyle(.secondary)
        }
    }

    private var tiles: some View {
        let total = records.reduce(0) { $0 + $1.integrationMinutes }
        let nights = Set(records.map(\.nightDate)).count
        let objects = Set(records.map(\.target)).count
        let frames = records.reduce(0) { $0 + $1.frames }
        let longest = records.max { $0.integrationMinutes < $1.integrationMinutes }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
            StatTile(title: tr("Integración"), value: hours(total), systemImage: "hourglass")
            StatTile(title: tr("Noches"), value: "\(nights)", systemImage: "moon.stars")
            StatTile(title: tr("Sesiones"), value: "\(records.count)", systemImage: "list.bullet")
            StatTile(title: tr("Objetos distintos"), value: "\(objects)", systemImage: "sparkles")
            StatTile(title: tr("Fotogramas"), value: frames.formatted(), systemImage: "square.stack.3d.up")
            StatTile(title: tr("Sesión más larga"), value: longest.map { hours($0.integrationMinutes) } ?? "—",
                     systemImage: "trophy", detail: longest?.target)
        }
    }

    private struct NightBar: Identifiable { let id: Date; let minutes: Double }

    private var perNightChart: some View {
        let grouped = Dictionary(grouping: records, by: \.nightDate)
            .map { NightBar(id: $0.key, minutes: $0.value.reduce(0) { $0 + $1.integrationMinutes }) }
            .sorted { $0.id < $1.id }
        return Card(title: tr("Integración por noche"), systemImage: "chart.bar.xaxis") {
            Chart(grouped) { b in
                BarMark(x: .value("Noche", b.id, unit: .day), y: .value("Horas", b.minutes / 60))
                    .foregroundStyle(LinearGradient(colors: [Theme.accentSoft, Theme.accent], startPoint: .top, endPoint: .bottom))
                    .cornerRadius(3)
            }
            .chartYAxisLabel("horas")
            .frame(height: 190)
        }
    }

    private struct KindBar: Identifiable { var id: String { kind }; let kind: String; let minutes: Double }

    private var perKindChart: some View {
        let grouped = Dictionary(grouping: records, by: { $0.kind?.rawValue ?? tr("Otro") })
            .map { KindBar(kind: $0.key, minutes: $0.value.reduce(0) { $0 + $1.integrationMinutes }) }
            .sorted { $0.minutes > $1.minutes }
        return Card(title: tr("Por tipo de objeto"), systemImage: "chart.pie") {
            Chart(grouped) { b in
                SectorMark(angle: .value("Minutos", b.minutes), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(by: .value("Tipo", b.kind))
                    .cornerRadius(3)
            }
            .frame(height: 190)
        }
    }

    private struct ObjectRow: Identifiable {
        var id: String { name }
        let name: String; let sessions: Int; let minutes: Double; let frames: Int; let last: Date
    }

    private var objectsTable: some View {
        let rows = Dictionary(grouping: records, by: \.target).map { name, rs in
            ObjectRow(name: name, sessions: rs.count, minutes: rs.reduce(0) { $0 + $1.integrationMinutes },
                      frames: rs.reduce(0) { $0 + $1.frames }, last: rs.map(\.start).max() ?? .distantPast)
        }.sorted { $0.minutes > $1.minutes }
        return Card(title: tr("Objetos"), systemImage: "star.circle") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text(tr("Objeto")).bold(); Text(tr("Sesiones")).bold(); Text(tr("Integración")).bold(); Text(tr("Fotogramas")).bold(); Text(tr("Última vez")).bold()
                }
                .foregroundStyle(.secondary)
                ForEach(rows) { r in
                    GridRow {
                        Text(Catalog.find(r.name)?.displayName ?? r.name)
                        Text("\(r.sessions)").monospacedDigit()
                        HStack(spacing: 6) {
                            Text(hours(r.minutes)).monospacedDigit().frame(width: 64, alignment: .leading)
                            Capsule().fill(Theme.accent.opacity(0.7))
                                .frame(width: max(2, 120 * r.minutes / max(1, rows.first?.minutes ?? 1)), height: 6)
                        }
                        Text(r.frames.formatted()).monospacedDigit()
                        Text(r.last.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Loc.shared.locale))).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var sessionsTable: some View {
        Card(title: tr("Sesiones"), systemImage: "clock") {
            Table(records, selection: $selection) {
                TableColumn(tr("Fecha")) { r in Text(r.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Loc.shared.locale))) }
                TableColumn(tr("Objeto")) { r in Text(r.target) }
                TableColumn(tr("Duración")) { r in Text(hours(r.integrationMinutes)).monospacedDigit() }.width(80)
                TableColumn(tr("Fotogramas")) { r in Text("\(r.frames)").monospacedDigit() }.width(80)
                TableColumn(tr("Exposición")) { r in Text("\(r.exposureMs / 1000) s").monospacedDigit() }.width(80)
            }
            .frame(minHeight: 200, idealHeight: 260)
            .scrollContentBackground(.hidden)
            HStack {
                Button(role: .destructive) { history.delete(selection); selection.removeAll() } label: {
                    Label(tr("Borrar seleccionadas"), systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Text(tr("La duración es fotogramas × exposición configurada.")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func hours(_ minutes: Double) -> String {
        minutes < 60 ? tr("%.0f min", minutes) : String(format: "%.1f h", minutes / 60)
    }

    private func importAlbum() {
        importing = true
        Task {
            defer { importing = false }
            do {
                let n = history.importFromAlbum(try await client.albums())
                message = n == 0 ? tr("No hay sesiones nuevas en el álbum.") : tr("Importadas %@ sesiones del álbum del Seestar.", "\(n)")
            } catch { message = error.localizedDescription }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "astrolabio_historial.csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try history.csv().write(to: url, atomically: true, encoding: .utf8)
                message = tr("Exportado a %@", "\(url.path)")
            } catch { message = error.localizedDescription }
        }
    }
}
