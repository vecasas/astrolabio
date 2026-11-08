import SwiftUI

/// Línea de tiempo del plan: cada objeto es una barra sobre la noche, con los tramos en que se ve
/// detrás. Se arrastra la barra para retrasar su inicio y su borde derecho para cambiar la duración.
/// «Simular la noche» recorre el plan del anochecer al amanecer en unos segundos.
@MainActor
struct PlanTimelineView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var plan: PlanStore

    @State private var dragOffset: [UUID: CGFloat] = [:]
    @State private var resizeOffset: [UUID: CGFloat] = [:]
    @State private var simTime: Date?
    @State private var simulating = false

    private let rowHeight: CGFloat = 34
    private let labelWidth: CGFloat = 130

    var body: some View {
        let night = Astro.night(for: Date(), lat: settings.latitude, lon: settings.longitude)
        let limit = settings.skyLimit
        let slots = PlanTimeline.schedule(plan.items, night: night, limit: limit, lat: settings.latitude, lon: settings.longitude)
        Card(title: tr("Línea de tiempo de la noche"), systemImage: "chart.bar.xaxis") {
            if let from = night.sunset ?? night.duskStart, let to = night.sunrise ?? night.dawnEnd, to > from {
                header(slots: slots, night: night)
                GeometryReader { geo in
                    let w = max(10, geo.size.width - labelWidth)
                    let span = to.timeIntervalSince(from)
                    let x: (Date) -> CGFloat = { d in labelWidth + CGFloat(d.timeIntervalSince(from) / span) * w }
                    let perMinute = w / CGFloat(span / 60)
                    ZStack(alignment: .topLeading) {
                        background(night: night, from: from, to: to, x: x, height: geo.size.height)
                        ForEach(Array(plan.items.enumerated()), id: \.element.id) { row, item in
                            if let slot = slots.first(where: { $0.itemID == item.id }) {
                                rowView(item: item, slot: slot, row: row, from: from, to: to, x: x, perMinute: perMinute, limit: limit)
                            } else {
                                Text("\(item.name) · \(statusText(item))").font(.caption).foregroundStyle(.secondary)
                                    .offset(x: 4, y: 24 + CGFloat(row) * rowHeight + 8)
                            }
                        }
                        if let t = simTime {
                            Rectangle().fill(Color.white.opacity(0.8)).frame(width: 2, height: geo.size.height)
                                .offset(x: x(t))
                        }
                    }
                }
                .frame(height: 30 + CGFloat(max(1, plan.items.count)) * rowHeight)
                Text(tr("Arrastra una barra para retrasar su inicio; arrastra su borde derecho para cambiar la duración. Detrás de cada barra, en verde, cuándo se ve el objeto (altura mínima y tu horizonte)."))
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(tr("Esta noche no llega a oscurecer del todo.")).foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(_ item: PlanItem) -> String {
        switch item.status {
        case .done: return tr("hecho")
        case .skipped: return tr("saltado")
        case .failed: return tr("fallido")
        default: return ""
        }
    }

    @ViewBuilder
    private func header(slots: [PlanSlot], night: Astro.Night) -> some View {
        HStack {
            if let last = slots.last, let dawn = night.dawnEnd {
                let free = dawn.timeIntervalSince(last.end) / 60
                Text(free >= 0 ? tr("El plan termina a las %@; sobran %@ min de noche.", last.end.shortTime, "\(Int(free))")
                               : tr("El plan termina a las %@, %@ min después del amanecer.", last.end.shortTime, "\(Int(-free))"))
                    .font(.callout).foregroundStyle(free >= 0 ? Color.secondary : Theme.warn)
            }
            let warnings = slots.filter(\.hasWarning).count
            if warnings > 0 {
                Label(tr("%@ objetos con avisos", "\(warnings)"), systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warn).font(.callout)
            }
            Spacer()
            if let t = simTime {
                let current = slots.first { $0.start <= t && t < $0.end }.flatMap { s in plan.items.first { $0.id == s.itemID } }
                Text("\(t.shortTime) · \(current?.name ?? tr("sin objeto"))").monospacedDigit().font(.callout)
            }
            Button(simulating ? tr("Parar") : tr("Simular la noche")) { simulating ? stopSim() : simulate(night: night) }
                .disabled(slots.isEmpty)
        }
    }

    private func background(night: Astro.Night, from: Date, to: Date, x: @escaping (Date) -> CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Noche cerrada.
            if let d = night.duskStart, let a = night.dawnEnd {
                Rectangle().fill(Color.indigo.opacity(0.18)).frame(width: max(0, x(a) - x(d)), height: height).offset(x: x(d))
            }
            // Luna sobre el horizonte.
            let moon = Ephemeris.moonAltitude(lat: settings.latitude, lon: settings.longitude)
            ForEach(Array(stride(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970, by: 900)), id: \.self) { t in
                let d = Date(timeIntervalSince1970: t)
                if moon(d) > 0 {
                    Rectangle().fill(Color.yellow.opacity(0.10 + 0.2 * Astro.moon(d).illumination))
                        .frame(width: max(1, x(d.addingTimeInterval(900)) - x(d)), height: 6).offset(x: x(d), y: 14)
                }
            }
            // Horas.
            ForEach(Array(stride(from: ceil(from.timeIntervalSince1970 / 3600) * 3600, to: to.timeIntervalSince1970, by: 3600)), id: \.self) { t in
                let d = Date(timeIntervalSince1970: t)
                Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1, height: height).offset(x: x(d))
                Text(d.formatted(.dateTime.hour())).font(.caption2).foregroundStyle(.secondary).offset(x: x(d) + 2, y: 0)
            }
            Text(tr("☾ Luna")).font(.caption2).foregroundStyle(.secondary).offset(x: 4, y: 10)
        }
    }

    @ViewBuilder
    private func rowView(item: PlanItem, slot: PlanSlot, row: Int, from: Date, to: Date, x: @escaping (Date) -> CGFloat,
                         perMinute: CGFloat, limit: SkyLimit) -> some View {
        let y = 24 + CGFloat(row) * rowHeight
        let windows = PlanTimeline.visibleWindows(item, from: from, to: to, limit: limit, lat: settings.latitude, lon: settings.longitude)
        let dx = dragOffset[item.id] ?? 0
        let dw = resizeOffset[item.id] ?? 0
        let barX = x(slot.start) + dx
        let barW = max(12, x(slot.end) - x(slot.start) + dw)
        let current = simTime.map { slot.start <= $0 && $0 < slot.end } ?? false
        ZStack(alignment: .topLeading) {
            Text(item.name).font(.caption.weight(.semibold)).lineLimit(1).frame(width: labelWidth - 8, alignment: .leading)
                .offset(x: 4, y: y + 8)
            ForEach(Array(windows.enumerated()), id: \.offset) { _, wnd in
                Rectangle().fill(Color.green.opacity(0.16))
                    .frame(width: max(1, x(wnd.upperBound) - x(wnd.lowerBound)), height: rowHeight - 6)
                    .offset(x: x(wnd.lowerBound), y: y + 3)
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(slot.hasWarning ? Theme.warn.opacity(0.8) : Theme.accent.opacity(current ? 1 : 0.75))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(current ? Color.white : Color.clear, lineWidth: 2))
                .overlay(alignment: .leading) {
                    HStack(spacing: 4) {
                        if slot.hasWarning { Image(systemName: "exclamationmark.triangle.fill") }
                        Text("\(slot.start.shortTime) · \(Int(item.minutes)) min").lineLimit(1)
                    }
                    .font(.caption2).foregroundStyle(.white).padding(.leading, 6)
                }
                .frame(width: barW, height: rowHeight - 10)
                .offset(x: barX, y: y + 5)
                .help(warningText(slot))
                .gesture(DragGesture().onChanged { g in dragOffset[item.id] = g.translation.width }
                    .onEnded { g in
                        dragOffset[item.id] = nil
                        let minutes = PlanTimeline.snap(Double(g.translation.width / perMinute))
                        guard let i = plan.items.firstIndex(where: { $0.id == item.id }), minutes != 0 else { return }
                        let newStart = slot.start.addingTimeInterval(minutes * 60)
                        // Hacia la izquierda de donde empezaría solo: se quita la espera.
                        plan.items[i].notBefore = minutes < 0 && newStart <= slot.start.addingTimeInterval(-slot.waitMinutes * 60) ? nil : newStart
                    })
            // Asa para cambiar la duración.
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: 10, height: rowHeight - 10)
                .overlay(Rectangle().fill(Color.white.opacity(0.6)).frame(width: 2, height: 14))
                .offset(x: barX + barW - 6, y: y + 5)
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture().onChanged { g in resizeOffset[item.id] = g.translation.width }
                    .onEnded { g in
                        resizeOffset[item.id] = nil
                        guard let i = plan.items.firstIndex(where: { $0.id == item.id }) else { return }
                        plan.items[i].minutes = max(5, min(600, PlanTimeline.snap(item.minutes + Double(g.translation.width / perMinute))))
                    })
        }
    }

    private func warningText(_ s: PlanSlot) -> String {
        var parts: [String] = []
        if s.hiddenMinutes >= 10 { parts.append(tr("%@ min por debajo de la altura mínima o detrás de tu horizonte", "\(Int(s.hiddenMinutes))")) }
        if s.afterDawn { parts.append(tr("termina después del amanecer")) }
        if s.waitMinutes >= 5 { parts.append(tr("espera %@ min antes de empezar", "\(Int(s.waitMinutes))")) }
        return parts.joined(separator: " · ")
    }

    private func simulate(night: Astro.Night) {
        guard let d = night.duskStart, let a = night.dawnEnd else { return }
        simulating = true
        Task {
            let steps = 240
            for k in 0...steps {
                guard simulating else { break }
                simTime = d.addingTimeInterval(a.timeIntervalSince(d) * Double(k) / Double(steps))
                try? await Task.sleep(for: .milliseconds(80))
            }
            simulating = false
            try? await Task.sleep(for: .seconds(2))
            if !simulating { simTime = nil }
        }
    }

    private func stopSim() { simulating = false; simTime = nil }
}
