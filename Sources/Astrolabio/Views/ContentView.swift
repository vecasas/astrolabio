import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case tonight = "Qué mirar"
    case pick = "Elige por mí"
    case skyChart = "Carta estelar"
    case telescope = "Telescopio"
    case live = "Vista en directo"
    case planner = "Planificar la noche"
    case session = "Sesión automática"
    case mosaic = "Mosaicos"
    case moon = "Luna"
    case planets = "Planetas"
    case stacker = "Apilador planetario"
    case album = "Álbum"
    case stats = "Estadísticas"
    case reports = "Informes"
    case weather = "Tiempo"
    case log = "Registro"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tonight: return "binoculars"
        case .pick: return "wand.and.stars"
        case .skyChart: return "map"
        case .telescope: return "scope"
        case .live: return "camera.aperture"
        case .planner: return "list.star"
        case .session: return "moon.stars"
        case .mosaic: return "square.grid.3x3"
        case .moon: return "moonphase.waxing.gibbous"
        case .planets: return "globe.europe.africa"
        case .stacker: return "square.stack.3d.down.right"
        case .album: return "photo.on.rectangle"
        case .stats: return "chart.bar.xaxis"
        case .reports: return "doc.richtext"
        case .weather: return "cloud.sun"
        case .log: return "text.alignleft"
        }
    }

    /// Grupos de la barra lateral.
    static let groups: [(title: String, items: [AppSection])] = [
        (tr("Esta noche"), [.tonight, .pick, .skyChart]),
        ("Observar", [.telescope, .live]),
        (tr("Sistema solar"), [.moon, .planets, .stacker]),
        ("Planificar", [.planner, .session, .mosaic]),
        ("Archivo", [.album, .stats, .reports]),
        ("Sistema", [.weather, .log]),
    ]
}

@MainActor
struct ContentView: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var runner: SessionRunner
    @EnvironmentObject var nav: AppNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.selection) {
                ForEach(AppSection.groups, id: \.title) { group in
                    SwiftUI.Section(tr(group.title)) {
                        ForEach(group.items) { section in
                            Label(section.label, systemImage: section.icon).tag(section)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar.ignoresSafeArea())
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .top) { BrandHeader().padding(.horizontal, 14).padding(.bottom, 6) }
            .safeAreaInset(edge: .bottom) { StatusFooter().padding(10) }
        } detail: {
            VStack(spacing: 0) {
                TopBar()
                Divider().overlay(Theme.cardStroke)
                Group {
                    switch nav.selection ?? .tonight {
                    case .tonight: TonightView()
                    case .pick: PickForMeView()
                    case .skyChart: SkyChartView()
                    case .telescope: TelescopeView()
                    case .live: LiveView()
                    case .planner: PlannerView()
                    case .session: SessionView()
                    case .mosaic: MosaicView()
                    case .moon: MoonView()
                    case .planets: PlanetsView()
                    case .stacker: StackerView()
                    case .album: AlbumView()
                    case .stats: StatsView()
                    case .reports: ReportsView()
                    case .weather: WeatherView()
                    case .log: LogView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .themedBackground()
        }
        .tint(Theme.accent)
    }
}

/// Nombre de la app en lo alto de la barra lateral.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(LinearGradient(colors: [Theme.accentSoft, Theme.accent], startPoint: .top, endPoint: .bottom))
            Text(tr("Astrolabio")).font(.system(.title3, design: .rounded).weight(.bold))
            Spacer()
            AboutButton()
        }
    }
}

/// Barra superior: hora local, temperatura (exterior y del Seestar), nubes, Luna y estado de la noche.
@MainActor
struct TopBar: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sky: SkyStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.accentSoft)
                    Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Loc.shared.locale)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                divider
                temperature
                if let c = sky.currentCloud {
                    item("cloud", String(format: "%.0f %%", c), tr("Nubes"))
                }
                let m = Astro.moon(now)
                item(moonSymbol(now), String(format: "%.0f %%", m.illumination * 100), "Luna")
                nightState(now)
                Spacer()
                NightModeButton()
                connection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Theme.deep.opacity(0.55))
        }
        .task(id: "\(settings.latitude),\(settings.longitude)") { sky.start(lat: settings.latitude, lon: settings.longitude) }
    }

    private var divider: some View {
        Rectangle().fill(Theme.cardStroke).frame(width: 1, height: 30)
    }

    @ViewBuilder
    private var temperature: some View {
        HStack(spacing: 14) {
            if let t = sky.currentTemperature {
                item("thermometer.medium", String(format: "%.0f °C", t), tr("Exterior"))
            }
            if let t = client.temperature, client.isConnected {
                item("scope", String(format: "%.0f °C", t), tr("Seestar"))
            }
            if sky.currentTemperature == nil && !(client.isConnected && client.temperature != nil) {
                item("thermometer.medium", "—", tr("Temperatura"))
            }
        }
    }

    private func item(_ icon: String, _ value: String, _ caption: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
                Text(tr(caption)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func nightState(_ now: Date) -> some View {
        let sunAlt = Astro.sunAltitude(now, lat: settings.latitude, lon: settings.longitude)
        let (icon, text): (String, String) = {
            switch sunAlt {
            case ..<(-18): return ("moon.stars.fill", tr("Noche cerrada"))
            case ..<(-12): return ("moon.haze", tr("Crepúsculo astronómico"))
            case ..<(-6): return ("sun.haze", tr("Crepúsculo náutico"))
            case ..<0: return ("sunset", tr("Crepúsculo civil"))
            default: return ("sun.max", tr("De día"))
            }
        }()
        return item(icon, text, tr("Sol a %.0f°", sunAlt))
    }

    private func moonSymbol(_ date: Date) -> String {
        let age = Astro.moonPhase(date).age
        switch age {
        case ..<1.8: return "moonphase.new.moon"
        case ..<5.5: return "moonphase.waxing.crescent"
        case ..<9.2: return "moonphase.first.quarter"
        case ..<12.9: return "moonphase.waxing.gibbous"
        case ..<16.6: return "moonphase.full.moon"
        case ..<20.3: return "moonphase.waning.gibbous"
        case ..<24.0: return "moonphase.last.quarter"
        case ..<27.7: return "moonphase.waning.crescent"
        default: return "moonphase.new.moon"
        }
    }

    private var connection: some View {
        HStack(spacing: 8) {
            Circle().fill(client.isConnected ? (client.isAuthenticated ? Theme.good : Theme.warn) : Color.gray)
                .frame(width: 9, height: 9)
            VStack(alignment: .trailing, spacing: 0) {
                Text(client.isConnected ? (client.deviceName.isEmpty ? "Seestar" : client.deviceName) : tr("Sin telescopio"))
                    .font(.callout.weight(.semibold))
                Text(client.isConnected ? (client.battery.map { tr("Batería %@ %%", "\($0)") } ?? client.host) : client.status.label)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.cardStroke))
    }
}

@MainActor
struct StatusFooter: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var runner: SessionRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(client.status.label).font(.caption).lineLimit(1)
            }
            if let b = client.battery {
                Label("\(b) %" + (client.chargerStatus == "Charging" ? tr(" · cargando") : ""),
                      systemImage: batteryIcon(b)).font(.caption).foregroundStyle(.secondary)
            }
            if runner.isRunning {
                Label(runner.phase.label, systemImage: "moon.stars.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var color: Color {
        switch client.status {
        case .connected: return client.isAuthenticated ? Theme.good : Theme.warn
        case .connecting: return .orange
        case .failed: return Theme.bad
        case .disconnected: return .gray
        }
    }

    private func batteryIcon(_ b: Int) -> String {
        switch b {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Piezas comunes

struct Card<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let systemImage {
                Label { Text(title) } icon: { Image(systemName: systemImage).foregroundStyle(Theme.accent) }
                    .font(.headline)
            }
            else { Text(title).font(.headline) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
    }
}

@MainActor
struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// Ejecuta una orden y muestra el error en una alerta si falla.
struct ActionRunner {
    static func run(_ client: SeestarClient, _ label: String, _ op: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await op()
                client.addLog(tr("%@: hecho.", "\(label)"))
            } catch {
                client.addLog("\(label): \(error.localizedDescription)", .error)
                let alert = NSAlert()
                alert.messageText = label
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

extension Date {
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
}
