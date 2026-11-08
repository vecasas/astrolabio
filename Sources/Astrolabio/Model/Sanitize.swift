import Foundation

/// Limpieza de datos que llegan del telescopio o de internet antes de usarlos en rutas,
/// archivos o enlaces. Ver docs/SEGURIDAD.md.
enum SafeName {
    /// Nombre de archivo o carpeta seguro a partir de un texto externo (nombre de objeto, carpeta
    /// del álbum…): sin separadores de ruta, sin «..», sin caracteres de control ni reservados de
    /// Windows, sin punto inicial y con una longitud razonable.
    static func fileComponent(_ s: String, fallback: String = "Seestar") -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var out = String(String.UnicodeScalarView(s.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
        out = out.replacingOccurrences(of: "..", with: "-")
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if out.count > 100 { out = String(out.prefix(100)) }
        return out.allSatisfy({ $0 == "-" || $0 == " " }) ? fallback : out
    }

    /// ¿Queda `child` dentro de `parent` una vez resueltos «..» y enlaces?
    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.resolvingSymlinksInPath().path
        let p = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }
}

enum CSV {
    /// Campo CSV entre comillas, con las comillas internas dobladas y sin fórmulas: un texto que
    /// empieza por = + - @ se prefija con un apóstrofo para que la hoja de cálculo no lo ejecute.
    static func field(_ s: String) -> String {
        var v = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if let f = v.first, "=+-@\t".contains(f) { v = "'" + v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

enum NetPolicy {
    /// Servidor de ntfy aceptable: HTTPS, o HTTP solo dentro de la red local (servidor propio).
    static func ntfyURL(server: String, topic: String) -> URL? {
        let t = topic.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 64,
              t.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }),
              let base = URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))),
              let scheme = base.scheme?.lowercased(), let host = base.host else { return nil }
        guard scheme == "https" || (scheme == "http" && isLocal(host)) else { return nil }
        return base.appendingPathComponent(t)
    }

    /// Dirección de la red local (para permitir HTTP sin cifrar solo ahí).
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
            || (p[0] == 169 && p[1] == 254)
    }

    /// Solo se abren enlaces de Wikipedia por HTTPS (el texto viene de internet).
    static func isWikipedia(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "wikipedia.org" || host.hasSuffix(".wikipedia.org")
    }

    /// Texto apto para una cabecera HTTP (sin saltos de línea, longitud limitada).
    static func headerValue(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(200))
    }
}
