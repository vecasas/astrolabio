import Foundation
import Testing
@testable import Astrolabio

@MainActor
struct LocalizationTests {
    /// Todas las claves tr("…") del código fuente.
    private func sourceKeys() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Astrolabio")
        let regex = try NSRegularExpression(pattern: #"tr\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "Translations.swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            let ns = src as NSString
            for m in regex.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range(at: 1))
                keys.insert(raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return Array(keys)
    }

    @Test func testEveryTextIsTranslated() throws {
        let keys = try sourceKeys()
        #expect(keys.count > 500)
        for lang in AppLanguage.allCases where lang != .es {
            let missing = Loc.shared.missing(keys, in: lang)
            #expect(missing.isEmpty, "Faltan en \(lang.rawValue): \(missing.prefix(10))")
        }
        // Nombres comunes del catálogo y planetas.
        let names = Catalog.objects.map(\.name).filter { !$0.isEmpty } + Astro.planetNames
        for lang in AppLanguage.allCases where lang != .es {
            #expect(Loc.shared.missing(names, in: lang).isEmpty, "Nombres sin traducir en \(lang.rawValue)")
        }
    }

    @Test func testSwitchingLanguage() {
        let original = Loc.shared.language
        defer { Loc.shared.setLanguage(original) }
        Loc.shared.setLanguage(.en)
        #expect(tr("Luna") == "Moon")
        #expect(tr("Apuntando a %@…", "M31") == "Slewing to M31…")
        #expect(ObjectKind.galaxy.label == "Galaxy")
        Loc.shared.setLanguage(.zh)
        #expect(tr("Luna") == "月亮")
        Loc.shared.setLanguage(.de)
        // Huecos numerados: el orden cambia en alemán sin romper el formato.
        #expect(tr("Está a %.0f° y sube hasta %.0f° hacia las %@.", 40.0, 70.0, "23:40") == "Es steht bei 40° und steigt bis gegen 23:40 auf 70°.")
        Loc.shared.setLanguage(.es)
        #expect(tr("Luna") == "Luna")
    }

    @Test func testFormattedTextsInAllLanguages() {
        let original = Loc.shared.language
        defer { Loc.shared.setLanguage(original) }
        for lang in AppLanguage.allCases {
            Loc.shared.setLanguage(lang)
            #expect(!tr("%@ fotogramas · %@ min", "12", "6").contains("%"))
            #expect(!tr("Le quedan %.1f h por encima de %.0f°: %.0f min de apilado dan buen resultado.", 2.5, 30.0, 90.0).contains("%"))
            #expect(tr("Batería %@ %%", "80").contains("80"))
            #expect(!Astro.moonPhase(Date()).name.isEmpty)
        }
    }
}
