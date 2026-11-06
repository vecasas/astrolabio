import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necesario cuando se lanza con `swift run`, sin paquete .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // El centro de notificaciones solo existe dentro de un paquete .app.
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Muestra los avisos también cuando Astrolabio está en primer plano.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AstrolabioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = AppSettings()
    @StateObject private var client = SeestarClient()
    @StateObject private var plan = PlanStore()
    @StateObject private var runner = SessionRunner()
    @StateObject private var live = LiveViewModel()
    @StateObject private var sky = SkyStore()
    @StateObject private var tonight = TonightModel()
    @StateObject private var nav = AppNavigation()
    @StateObject private var history = ObservationLog()
    @ObservedObject private var loc = Loc.shared

    var body: some Scene {
        WindowGroup("Astrolabio", id: "main") {
            ContentView()
                .id(loc.revision)
                .environment(\.locale, loc.locale)
                .environmentObject(settings)
                .environmentObject(client)
                .environmentObject(plan)
                .environmentObject(runner)
                .environmentObject(live)
                .environmentObject(sky)
                .environmentObject(tonight)
                .environmentObject(nav)
                .environmentObject(history)
                .preferredColorScheme(.dark)
                .nightMode(settings)
                .frame(minWidth: 1180, minHeight: 760)
                .task { await wireUp() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) { AboutCommand() }
            CommandGroup(after: .windowArrangement) { StarPartyCommand() }
            CommandMenu(tr("Idioma")) {
                ForEach(AppLanguage.allCases) { l in
                    Button((l == loc.language ? "✓ " : "   ") + l.nativeName) { loc.setLanguage(l) }
                }
            }
            CommandGroup(after: .toolbar) {
                Button(tr("Modo nocturno")) { settings.toggleNightMode() }
                    .keyboardShortcut("n", modifiers: [.control, .command])
            }
        }

        Window(tr("Fiesta de estrellas"), id: "starparty") {
            StarPartyView()
                .id(loc.revision)
                .environmentObject(live)
                .environmentObject(client)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .nightMode(settings)
        }

        Window(tr("Acerca de Astrolabio"), id: "about") {
            AboutView()
                .id(loc.revision)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .nightMode(settings)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .id(loc.revision)
                .environmentObject(settings)
                .environmentObject(client)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .nightMode(settings)
                .frame(width: 640, height: 780)
        }
    }

    @MainActor
    private func wireUp() async {
        DebugSnapshot.nav = nav
        DebugSnapshot.settings = settings
        DebugSnapshot.client = client
        DebugSnapshot.runIfRequested()
        let s = settings
        client.signerProvider = { s.makeSigner() }
        live.attach(to: client)
        history.attach(to: client, exposureMs: { s.exposureMs })
        if settings.autoConnect && !client.isConnected {
            await client.connect(to: settings.telescopeHost)
            if client.isConnected { live.connect(host: settings.telescopeHost) }
        }
    }
}

/// Menú Ventana › Fiesta de estrellas (⌃⌘F), como indica el README.
struct StarPartyCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(tr("Fiesta de estrellas")) { openWindow(id: "starparty") }
            .keyboardShortcut("f", modifiers: [.control, .command])
    }
}
