import Foundation

typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    /// Lee un valor anidado con una ruta tipo "result.device.firmware_ver_int".
    func value(at path: String) -> Any? {
        var current: Any? = self
        for part in path.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(part)]
        }
        return current
    }

    func double(_ path: String) -> Double? {
        switch value(at: path) {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    func int(_ path: String) -> Int? {
        switch value(at: path) {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    func string(_ path: String) -> String? {
        switch value(at: path) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    func bool(_ path: String) -> Bool? {
        switch value(at: path) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "true" || s == "1"
        default: return nil
        }
    }
}

enum JSONText {
    static func encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func decode(_ text: String) -> JSONObject? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }
}
