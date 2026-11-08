import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Listas de observación (Messier y Caldwell) y planificador del maratón Messier.
@MainActor
struct ListsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var history: ObservationLog
    @EnvironmentObject var plan: PlanStore

    enum Tab: String, CaseIterable, Identifiable {
        case messier = "Messier", caldwell = "Caldwell", marathon = "Maratón Messier"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .messier
    @State private var status: ListStatus = .all
    @State private var tonight: [String: Double] = [:]
    @State private var message = ""

    private var night: Astro.Night { Astro.night(for: Date(), lat: settings.latitude, lon: settings.longitude) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text(tr($0.rawValue)).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 420)
                Spacer()
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(Theme.accentSoft) }
            }
            switch tab {
            case .messier: listView(.messier)
            case .caldwell: listView(.caldwell)
            case .marathon: MarathonView(message: $message)
            }
        }
        .padding(20)
        .task(id: "\(settings.latitude),\(settings.longitude),\(settings.minAltitude)") {
            let n = night, lat = settings.latitude, lon = settings.longitude, minAlt = settings.minAltitude
            tonight = await Task.detached {
                var d: [String: Double] = [:]
                for l in ObservingList.allCases {
                    for e in l.entries { if let o = e.object { d[o.id] = ObservingLists.usableTonight(o, night: n, lat: lat, lon: lon, minAltitude: minAlt) } }
                }
                return d
            }.value
        }
    }

    @ViewBuilder
    private func listView(_ list: ObservingList) -> some View {
        let imaged = ObservingLists.imaged(history.allRecords)
        let entries = list.entries
        let done = entries.filter { $0.object.map { imaged.contains($0.id) } ?? false }.count
        let rows = entries.filter { e in
            guard let o = e.object else { return status == .all || status == .pending }
            let isDone = imaged.contains(o.id)
            switch status {
            case .all: return true
            case .done: return isDone
            case .pending: return !isDone
            case .pendingTonight: return !isDone && (tonight[o.id] ?? 0) > 0
            }
        }
        HStack {
            Label(tr("%@ de %@ fotografiados", "\(done)", "\(entries.count)"), systemImage: "checkmark.seal")
                .font(.headline)
            ProgressView(value: Double(done), total: Double(entries.count)).frame(width: 200)
            Spacer()
            Picker(tr("Mostrar"), selection: $status) { ForEach(ListStatus.allCases) { Text(tr($0.rawValue)).tag($0) } }
                .frame(width: 360)
            Button(tr("Exportar CSV")) { exportCSV(list, imaged: imaged) }
        }
        Table(rows) {
            TableColumn(tr("Nº")) { e in Text(e.label).monospacedDigit() }.width(50)
            TableColumn(tr("Objeto")) { e in Text(e.object?.id ?? "—") }.width(90)
            TableColumn(tr("Nombre")) { e in Text(e.object?.localizedName ?? "").foregroundStyle(.secondary) }
            TableColumn(tr("Tipo")) { e in Text(e.object?.kind.label ?? "") }.width(140)
            TableColumn(tr("Mag")) { e in Text(e.object.map { String(format: "%.1f", $0.magnitude) } ?? "").monospacedDigit() }.width(45)
            TableColumn(tr("Esta noche")) { e in
                let m = e.object.flatMap { tonight[$0.id] } ?? 0
                Text(m > 0 ? tr("%@ h", String(format: "%.1f", m / 60)) : tr("No sale")).foregroundStyle(m > 0 ? .primary : .secondary)
            }.width(80)
            TableColumn(tr("Estado")) { e in
                if let o = e.object, imaged.contains(o.id) {
                    Label(tr("Hecho"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                } else {
                    Text(tr("Pendiente")).foregroundStyle(.secondary)
                }
            }.width(100)
            TableColumn("") { e in
                if let o = e.object {
                    Button(tr("Al plan")) {
                        plan.add(o)
                        message = tr("%@ añadido al plan.", o.id)
                    }
                    .buttonStyle(.borderless)
                }
            }.width(70)
        }
    }

    private func exportCSV(_ list: ObservingList, imaged: Set<String>) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "astrolabio_\(list.rawValue.lowercased()).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ObservingLists.csv(list, imaged: imaged, tonight: tonight).write(to: url, atomically: true, encoding: .utf8)
            message = tr("Exportado a %@", url.lastPathComponent)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Orden del maratón Messier para una noche (mejor cerca de la Luna nueva de marzo o abril).
@MainActor
struct MarathonView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var plan: PlanStore
    @Binding var message: String
    @State private var date = Date()
    @State private var minutes = 4.0
    @State private var result: (steps: [MarathonStep], missed: [DeepSkyObject]) = ([], [])

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                DatePicker(tr("Noche del"), selection: $date, displayedComponents: .date).frame(width: 220)
                Stepper(value: $minutes, in: 2...15, step: 1) { Text(tr("%@ min por objeto", "\(Int(minutes))")) }
                Spacer()
                Button(tr("Usar como plan de la noche")) {
                    plan.items = result.steps.map { s in
                        var item = PlanItem(name: s.object.id, raHours: s.object.raHours, decDeg: s.object.decDeg, minutes: minutes)
                        item.autofocus = false
                        return item
                    }
                    message = tr("Plan con %@ objetos creado. Revísalo en «Sesión automática».", "\(result.steps.count)")
                }
                .disabled(result.steps.isEmpty)
            }
            Text(tr("Se ordenan para ver cada objeto antes de que se ponga: primero los del oeste al anochecer y al final los que salen por el este al amanecer. Con el Seestar, cada objeto necesita además el tiempo del GoTo."))
                .font(.caption).foregroundStyle(.secondary)
            Text(tr("%@ de 110 objetos en orden · %@ no se pueden ver esa noche desde tu lugar", "\(result.steps.count)", "\(result.missed.count)"))
                .font(.headline)
            Table(result.steps) {
                TableColumn(tr("Hora")) { s in Text(s.time.shortTime).monospacedDigit() }.width(60)
                TableColumn(tr("Objeto")) { s in Text(s.object.id) }.width(70)
                TableColumn(tr("Nombre")) { s in Text(s.object.localizedName).foregroundStyle(.secondary) }
                TableColumn(tr("Tipo")) { s in Text(s.object.kind.label) }.width(140)
                TableColumn(tr("Altura")) { s in Text("\(Int(s.altitude))°").monospacedDigit() }.width(60)
            }
            if !result.missed.isEmpty {
                Text(tr("No visibles: %@", result.missed.map(\.id).joined(separator: ", "))).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(date.timeIntervalSince1970)|\(minutes)") {
            let n = Astro.night(for: date, lat: settings.latitude, lon: settings.longitude)
            let lat = settings.latitude, lon = settings.longitude, m = minutes
            result = await Task.detached { Marathon.plan(night: n, lat: lat, lon: lon, minutesPerObject: m) }.value
        }
    }
}
