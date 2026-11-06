import Foundation
import SwiftUI

/// Idiomas de la interfaz.
enum AppLanguage: String, CaseIterable, Identifiable {
    case es, en, fr, de, zh, ru
    var id: String { rawValue }

    /// Nombre del idioma en su propia lengua.
    var nativeName: String {
        switch self {
        case .es: return "Español"
        case .en: return "English"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .zh: return "中文"
        case .ru: return "Русский"
        }
    }

    var locale: Locale {
        switch self {
        case .zh: return Locale(identifier: "zh-Hans")
        default: return Locale(identifier: rawValue)
        }
    }

    /// Dominio de la Wikipedia de ese idioma.
    var wikipedia: String { "\(rawValue).wikipedia.org" }

    /// El idioma del sistema si está entre los disponibles; si no, español.
    static var systemDefault: AppLanguage {
        for id in Locale.preferredLanguages {
            let code = String(id.prefix(2))
            if let l = AppLanguage(rawValue: code) { return l }
        }
        return .es
    }
}

/// Traducciones de la interfaz. El texto en español es la clave; las tablas de los demás idiomas
/// están en Translations.swift. Si falta una traducción se muestra el español.
final class Loc: ObservableObject, @unchecked Sendable {
    static let shared = Loc()

    private let lock = NSLock()
    private var _language: AppLanguage
    private var tables: [AppLanguage: [String: String]] = [:]

    @MainActor @Published private(set) var revision = 0

    init() {
        let saved = UserDefaults.standard.string(forKey: "language").flatMap(AppLanguage.init(rawValue:))
        _language = saved ?? AppLanguage.systemDefault
        tables = Translations.load()
    }

    var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return _language
    }

    var locale: Locale { language.locale }

    @MainActor
    func setLanguage(_ l: AppLanguage) {
        lock.lock(); _language = l; lock.unlock()
        UserDefaults.standard.set(l.rawValue, forKey: "language")
        revision += 1
    }

    func translate(_ key: String) -> String {
        let lang = language
        if lang == .es { return key }
        lock.lock(); defer { lock.unlock() }
        return tables[lang]?[key] ?? key
    }

    /// Claves sin traducir en un idioma (para las pruebas).
    func missing(_ keys: [String], in lang: AppLanguage) -> [String] {
        keys.filter { tables[lang]?[$0] == nil }
    }
}

/// Traduce un texto de la interfaz (escrito en español).
func tr(_ key: String) -> String { Loc.shared.translate(key) }

/// Traduce un texto con huecos de formato (%@, %d, %.1f…) y los rellena.
func tr(_ key: String, _ args: CVarArg...) -> String {
    String(format: Loc.shared.translate(key), locale: Locale(identifier: "en_US_POSIX"), arguments: args)
}

extension Date {
    /// Fecha formateada en el idioma de la interfaz.
    func localized(_ style: Date.FormatStyle) -> String {
        formatted(style.locale(Loc.shared.locale))
    }
}

// Etiquetas traducidas de los valores que se muestran en pantalla.
extension ObjectKind { var label: String { tr(rawValue) } }
extension AppSection { var label: String { tr(rawValue) } }
extension PickStyle { var label: String { tr(rawValue) } }

extension DeepSkyObject {
    /// Nombre común traducido («Galaxia de Andrómeda» → «Andromeda Galaxy»…).
    var localizedName: String { name.isEmpty ? "" : tr(name) }
}

/// Nombre traducido de un planeta (los datos internos usan el nombre en español).
func planetLabel(_ name: String) -> String { tr(name) }
