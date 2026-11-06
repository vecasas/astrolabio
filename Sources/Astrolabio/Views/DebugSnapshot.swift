import AppKit
import SwiftUI

/// Modo de diagnóstico: si se lanza con ASTROLABIO_SNAPSHOT=<carpeta>, recorre las secciones,
/// guarda una captura PNG de la ventana de cada una (sin necesitar permiso de grabación de
/// pantalla) y se cierra. No se activa en el uso normal.
@MainActor
enum DebugSnapshot {
    static weak var nav: AppNavigation?
    static weak var settings: AppSettings?
    static weak var client: SeestarClient?

    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["ASTROLABIO_SNAPSHOT"], !dir.isEmpty else { return }
        let only = ProcessInfo.processInfo.environment["ASTROLABIO_SNAPSHOT_SECTIONS"]?
            .split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let folder = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let sections = AppSection.allCases.filter { only == nil || only!.contains("\($0)") }
            for section in sections {
                nav?.selection = section
                try? await Task.sleep(for: .seconds([.tonight, .pick, .mosaic].contains(section) ? 9 : 3))
                save(to: folder.appendingPathComponent("\(section).png"))
            }
            if only?.contains("settings") == true {
                if let s = settings, let c = client {
                    let host = NSHostingView(rootView: SettingsView().environmentObject(s).environmentObject(c)
                        .preferredColorScheme(.dark).tint(Theme.accent).frame(width: 640, height: 1500))
                    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1500), styleMask: [.titled], backing: .buffered, defer: false)
                    w.contentView = host
                    w.orderFront(nil)
                    try? await Task.sleep(for: .seconds(2))
                    let v = host
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("settings.png"))
                    }
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func save(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
