import Foundation
import Darwin

struct DiscoveredScope: Identifiable, Hashable {
    var id: String { ip }
    let ip: String
    let name: String
    let model: String
}

/// Busca telescopios Seestar en la red local enviando `scan_iscope` por difusión UDP al
/// puerto 4720. Cada telescopio responde con un JSON que incluye su nombre.
enum SeestarDiscovery {
    static let port: UInt16 = 4720

    static func scan(timeout: TimeInterval = 3) async -> [DiscoveredScope] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: scanBlocking(timeout: timeout))
            }
        }
    }

    private static func scanBlocking(timeout: TimeInterval) -> [DiscoveredScope] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return [] }
        defer { close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload = #"{"id":1,"method":"scan_iscope","params":""}"# + "\r\n"
        let bytes = Array(payload.utf8)

        func sendTo(_ address: String) {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, address, &addr.sin_addr)
            _ = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        let targets = ["255.255.255.255"] + subnetBroadcastAddresses()
        for t in Set(targets) { sendTo(t) }

        var found: [String: DiscoveredScope] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        var resent = false
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(sock, &buffer, capacity, 0, sa, &fromLen)
                }
            }
            if n > 0 {
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: ipBuf)
                let text = String(decoding: buffer[0..<n], as: UTF8.self)
                for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
                    guard let obj = JSONText.decode(line) else { continue }
                    // Ignoramos nuestra propia petición si vuelve por la interfaz local.
                    if (obj["method"] as? String) == "scan_iscope" && obj["result"] == nil { continue }
                    let name = obj.string("result.device_name") ?? obj.string("result.name")
                        ?? obj.string("name") ?? "Seestar"
                    let model = obj.string("result.product_model") ?? obj.string("product_model") ?? ""
                    let reportedIP = obj.string("result.ip") ?? ip
                    found[reportedIP] = DiscoveredScope(ip: reportedIP, name: name, model: model)
                }
            } else if !resent && Date().addingTimeInterval(timeout / 2) > deadline {
                for t in Set(targets) { sendTo(t) }
                resent = true
            }
        }
        return found.values.sorted { $0.ip < $1.ip }
    }

    /// Direcciones de difusión de las interfaces IPv4 activas (p. ej. 192.168.0.255).
    private static func subnetBroadcastAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(bitPattern: cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
               (flags & IFF_BROADCAST) != 0, let dst = cur.pointee.ifa_dstaddr {
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var a = sin.pointee.sin_addr
                    inet_ntop(AF_INET, &a, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                }
                let s = String(cString: ipBuf)
                if !s.isEmpty && s != "0.0.0.0" { result.append(s) }
            }
            ptr = cur.pointee.ifa_next
        }
        return result
    }
}
