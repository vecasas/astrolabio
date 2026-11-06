import Foundation

/// Datos de la aplicación que se muestran en «Acerca de Astrolabio».
/// Para cambiar el autor o el contacto, edita solo este archivo.
enum AppInfo {
    static let name = "Astrolabio"
    static let version = "1.2.0"
    static let build = "3"
    static let author = "Víctor Casas"
    static let email = "vecasas@gmail.com"
    static let repository = "https://github.com/vecasas/astrolabio"
    /// Fecha de creación: 5 de noviembre de 2026.
    static let created: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 5; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }()

    /// Versión que lleva el paquete .app (si existe), o la del código.
    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? version
    }
}
