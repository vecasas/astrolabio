import SwiftUI
import AppKit

@MainActor
struct SessionView: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var plan: PlanStore
    @EnvironmentObject var runner: SessionRunner
    @EnvironmentObject var history: ObservationLog

    @State private var editing: PlanItem.ID?

    var body: some View {
        HSplitView {
            VSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    planList
                    Divider()
                    planFooter.padding(12)
                }
                .frame(minHeight: 200)
                ScrollView { PlanTimelineView().padding(12) }
                    .frame(minHeight: 180)
            }
            .frame(minWidth: 400, idealWidth: 600)
            VStack(alignment: .leading, spacing: 12) {
                runCard
                messages
            }
            .padding(16)
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 460)
        }
        .navigationTitle(tr("Sesión automática"))
        .sheet(item: Binding(get: { editing.flatMap { id in plan.items.first { $0.id == id } } },
                             set: { editing = $0?.id })) { item in
            PlanItemEditor(item: item) { updated in
                if let i = plan.items.firstIndex(where: { $0.id == updated.id }) { plan.items[i] = updated }
                editing = nil
            }
            .nightMode()
        }
    }

    private var planList: some View {
        List {
            if plan.items.isEmpty {
                Text(tr("El plan está vacío. Añade objetos desde «Planificar la noche» o «Mosaicos»."))
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.items) { item in
                HStack(spacing: 10) {
                    statusIcon(item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.headline)
                        Text(detailText(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.status == .running || item.stackedFrames > 0 {
                        Text(tr("%@ fot.", "\(item.stackedFrames)")).font(.caption).monospacedDigit()
                    }
                    Button(tr("Editar")) { editing = item.id }.buttonStyle(.borderless)
                }
                .padding(.vertical, 3)
                .listRowBackground(runner.currentItemID == item.id ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            .onMove { plan.items.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { plan.items.remove(atOffsets: $0) }
        }
    }

    private var planFooter: some View {
        HStack {
            Text(tr("Total: %@ min en %@ objetos", "\(Int(plan.items.reduce(0) { $0 + $1.minutes }))", "\(plan.items.count)"))
                .foregroundStyle(.secondary)
            Spacer()
            Button(tr("Reiniciar estados")) { plan.resetStatuses() }.disabled(runner.isRunning)
            Button(tr("Vaciar")) { plan.items.removeAll() }.disabled(runner.isRunning || plan.items.isEmpty)
        }
    }

    private var runCard: some View {
        Card(title: tr("Ejecutar el plan"), systemImage: "moon.stars") {
            Toggle(tr("Esperar a la noche astronómica"), isOn: $runner.options.waitForDark)
            Toggle(tr("Pausar si se prevén nubes (más de %@ %%)", "\(Int(settings.maxCloudCover))"), isOn: $runner.options.pauseForClouds)
            Toggle(tr("Parar al amanecer"), isOn: $runner.options.stopAtDawn)
            Picker(tr("Al terminar"), selection: $settings.endAction) {
                ForEach(EndAction.allCases) { Text($0.label).tag($0) }
            }
            Toggle(tr("Crear los oscuros antes de terminar"), isOn: $settings.darksAtEnd)
            batteryLine
            HStack {
                if runner.isRunning {
                    Button(tr("Saltar objeto")) { runner.skip() }
                    Button(tr("Detener"), role: .destructive) { runner.stop() }
                } else {
                    Button(tr("Empezar")) { startWithBatteryCheck() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!client.isConnected || !plan.items.contains { $0.status == .pending })
                }
            }
            Divider()
            InfoRow(label: tr("Estado"), value: runner.phase.label)
            if runner.phase == .stacking {
                InfoRow(label: tr("Queda en este objeto"), value: tr("%@ min", "\(Int(runner.remainingSeconds / 60))"))
            }
            if !runner.currentPanel.isEmpty { InfoRow(label: tr("Panel"), value: runner.currentPanel) }
            if !client.isConnected {
                Text(tr("Conecta el telescopio para empezar.")).font(.caption).foregroundStyle(.orange)
            }
            Text(tr("Deja el Mac encendido y la app abierta durante la sesión. Activa los avisos al móvil en Ajustes."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// Estimación de batería: consumo medio de tus sesiones anteriores.
    private var batteryEstimate: (hours: Double, drain: Double, end: Double)? {
        guard let b = client.battery else { return nil }
        let hours = BatteryEstimate.planHours(plan.items)
        let drain = BatteryEstimate.drainPerHour(history.allRecords)
        return (hours, drain, BatteryEstimate.expectedAtEnd(battery: b, hours: hours, drainPerHour: drain))
    }

    private var charging: Bool { client.chargerStatus == "Charging" || client.chargerStatus == "Full" }

    @ViewBuilder private var batteryLine: some View {
        if let e = batteryEstimate, e.hours > 0 {
            let low = !charging && e.end < BatteryEstimate.reserve
            Label(charging
                  ? tr("Batería: el telescopio está cargando.")
                  : tr("Batería prevista al terminar: %@ %% (plan de %@ h, consumo medio %@ %%/h).",
                       "\(max(0, Int(e.end)))", String(format: "%.1f", e.hours), String(format: "%.0f", e.drain)),
                  systemImage: low ? "battery.25percent" : "battery.75percent")
                .font(.caption).foregroundStyle(low ? Theme.warn : .secondary)
        }
    }

    private func startWithBatteryCheck() {
        if let b = client.battery, let e = batteryEstimate,
           !BatteryEstimate.isEnough(battery: b, charging: charging, hours: e.hours, drainPerHour: e.drain) {
            let a = NSAlert()
            a.messageText = tr("Puede que la batería no aguante el plan")
            a.informativeText = tr("El Seestar tiene un %@ %% y el plan dura unas %@ h; con tu consumo medio (%@ %%/h) terminaría sin batería. Conecta el cargador o acorta el plan.",
                                   "\(b)", String(format: "%.1f", e.hours), String(format: "%.0f", e.drain))
            a.addButton(withTitle: tr("Empezar igualmente"))
            a.addButton(withTitle: tr("Cancelar"))
            a.alertStyle = .warning
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        runner.start(client: client, settings: settings, plan: plan)
    }

    private var messages: some View {
        Card(title: tr("Qué está pasando"), systemImage: "text.bubble") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(runner.messages.enumerated()), id: \.offset) { i, m in
                            Text(m).font(.caption.monospaced()).id(i).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 200)
                .onChange(of: runner.messages.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }

    private func detailText(_ item: PlanItem) -> String {
        var parts = ["\(Int(item.minutes)) min"]
        if item.isMosaic { parts.append(tr("mosaico %@×%@", "\(item.mosaicColumns)", "\(item.mosaicRows)")) }
        if item.lpFilter { parts.append(tr("filtro LP")) }
        if item.autofocus { parts.append("enfoque") }
        if let nb = item.notBefore { parts.append("desde \(nb.shortTime)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusIcon(_ item: PlanItem) -> some View {
        switch item.status {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: Image(systemName: "play.circle.fill").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "forward.circle").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

@MainActor
struct PlanItemEditor: View {
    @State var item: PlanItem
    let onSave: (PlanItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var useNotBefore = false

    var body: some View {
        Form {
            TextField(tr("Nombre"), text: $item.name)
            Stepper(tr("Duración: %@ min", "\(Int(item.minutes))"), value: $item.minutes, in: 10...600, step: 10)
            Toggle(tr("Filtro antipolución (LP)"), isOn: $item.lpFilter)
            Toggle(tr("Enfoque automático antes de empezar"), isOn: $item.autofocus)
            Stepper(tr("Columnas del mosaico: %@", "\(item.mosaicColumns)"), value: $item.mosaicColumns, in: 1...3)
            Stepper(tr("Filas del mosaico: %@", "\(item.mosaicRows)"), value: $item.mosaicRows, in: 1...3)
            if item.isMosaic {
                Stepper(tr("Solape: %@ %%", "\(Int(item.overlapPercent))"), value: $item.overlapPercent, in: 5...40, step: 5)
            }
            Toggle(tr("No empezar antes de una hora"), isOn: $useNotBefore)
            if useNotBefore {
                DatePicker(tr("Hora"), selection: Binding(get: { item.notBefore ?? Date() }, set: { item.notBefore = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
            }
            HStack {
                Spacer()
                Button(tr("Cancelar")) { dismiss() }
                Button(tr("Guardar")) {
                    if !useNotBefore { item.notBefore = nil }
                    onSave(item)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { useNotBefore = item.notBefore != nil }
    }
}
