import Testing
import Foundation
@testable import Astrolabio

/// Pruebas de las defensas descritas en SEGURIDAD.md.
@MainActor
struct SecurityTests {
    @Test func testFileNamesFromTheScopeCannotEscape() {
        #expect(SafeName.fileComponent("M 31") == "M 31")
        let evil = SafeName.fileComponent("../../Library/LaunchAgents")
        #expect(!evil.contains("/") && !evil.contains("..") && evil.hasSuffix("Library-LaunchAgents"))
        #expect(!SafeName.fileComponent("..\\..\\Windows").contains("\\"))
        #expect(SafeName.fileComponent("...") == "Seestar")
        #expect(SafeName.fileComponent("") == "Seestar")
        #expect(SafeName.fileComponent(".oculto") == "oculto")
        #expect(SafeName.fileComponent("a\u{0}b\nc") == "a-b-c")
        #expect(SafeName.fileComponent(String(repeating: "x", count: 500)).count == 100)
        let base = URL(fileURLWithPath: "/tmp/astro-base")
        #expect(SafeName.isInside(base.appendingPathComponent("M 31/img.jpg"), base))
        #expect(!SafeName.isInside(base.appendingPathComponent("../fuera.jpg"), base))
        #expect(!SafeName.isInside(URL(fileURLWithPath: "/tmp/astro-base-otra/x"), base))
    }

    @Test func testCSVEscaping() {
        #expect(CSV.field("M 31") == "\"M 31\"")
        #expect(CSV.field("a\"b") == "\"a\"\"b\"")
        #expect(CSV.field("=HYPERLINK(\"http://x\")") == "\"'=HYPERLINK(\"\"http://x\"\")\"")
        #expect(CSV.field("+1") == "\"'+1\"")
        #expect(!CSV.field("a\nb").contains("\n"))
        let log = ObservationLog(storage: FileManager.default.temporaryDirectory.appendingPathComponent("sec-\(UUID()).json"))
        log.add(ObservationRecord(target: "=cmd|' /C calc'!A0", start: Date(), end: Date(), frames: 5, exposureMs: 10_000))
        #expect(log.csv().contains("\"'=cmd"))
    }

    @Test func testNtfyOnlyOverHTTPS() {
        #expect(NetPolicy.ntfyURL(server: "https://ntfy.sh", topic: "astrolabio-7k2m")?.absoluteString == "https://ntfy.sh/astrolabio-7k2m")
        #expect(NetPolicy.ntfyURL(server: "http://ntfy.sh", topic: "abc") == nil)              // sin cifrar por internet
        #expect(NetPolicy.ntfyURL(server: "http://192.168.1.10:8080", topic: "abc") != nil)    // servidor propio en casa
        #expect(NetPolicy.ntfyURL(server: "https://ntfy.sh", topic: "../admin") == nil)
        #expect(NetPolicy.ntfyURL(server: "https://ntfy.sh", topic: "a b") == nil)
        #expect(NetPolicy.ntfyURL(server: "https://ntfy.sh", topic: "") == nil)
        #expect(NetPolicy.ntfyURL(server: "file:///etc", topic: "abc") == nil)
        #expect(NetPolicy.headerValue("Hola\r\nX-Inyectada: 1") == "Hola  X-Inyectada: 1")
    }

    @Test func testLocalAndWikipediaPolicies() {
        for h in ["192.168.0.37", "10.0.0.5", "172.20.1.1", "localhost", "seestar.local", "127.0.0.1"] { #expect(NetPolicy.isLocal(h), "\(h)") }
        for h in ["8.8.8.8", "172.32.0.1", "example.com", "192.168.1", "999.1.1.1"] { #expect(!NetPolicy.isLocal(h), "\(h)") }
        #expect(NetPolicy.isWikipedia(URL(string: "https://es.wikipedia.org/wiki/M31")!))
        #expect(!NetPolicy.isWikipedia(URL(string: "http://es.wikipedia.org/wiki/M31")!))
        #expect(!NetPolicy.isWikipedia(URL(string: "https://wikipedia.org.malo.com/x")!))
        #expect(!NetPolicy.isWikipedia(URL(string: "javascript:alert(1)")!))
    }

    /// ZIP con una entrada deflate que declara 3 GB descomprimidos: no debe reservar esa memoria.
    @Test func testZipBombIsRejected() {
        var zip = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { zip.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { zip.append(contentsOf: $0) } }
        let name = Array("raw_data".utf8)
        let payload: [UInt8] = [0x03, 0x00]          // deflate vacío
        u32(0x04034B50); u16(20); u16(0); u16(8); u16(0); u16(0); u32(0); u32(UInt32(payload.count)); u32(3_000_000_000)
        u16(UInt16(name.count)); u16(0); zip.append(contentsOf: name); zip.append(contentsOf: payload)
        #expect(ZipReader.extract("raw_data", from: zip) == nil)
        #expect(ZipReader.inflate(Data(payload), expectedSize: 3_000_000_000) == nil)
        #expect(ZipReader.extract("raw_data", from: Data([0x50, 0x4B, 0x05])) == nil)   // basura
        #expect(ZipReader.extract("raw_data", from: Data()) == nil)
    }

    @Test func testPEMLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pem-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = dir.appendingPathComponent("grande.pem")
        try Data(repeating: 0x41, count: SeestarSigner.maxPEMBytes + 1).write(to: big)
        #expect(throws: (any Error).self) { _ = try SeestarSigner(pemURL: big) }
        let open = dir.appendingPathComponent("abierta.pem")
        try Data("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".utf8).write(to: open)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: open.path)
        #expect(SeestarSigner.permissionsWarning(for: open.path) != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: open.path)
        #expect(SeestarSigner.permissionsWarning(for: open.path) == nil)
        #expect(throws: (any Error).self) { _ = try SeestarSigner(pemURL: open) }       // no es una clave real
    }

    /// La cabecera FITS ocupa bloques de 2880 bytes de ASCII aunque el nombre tenga acentos o chino.
    @Test func testFITSHeaderIsASCII() throws {
        let img = LinearImage(width: 4, height: 3, r: [Float](repeating: 0.5, count: 12), g: [Float](repeating: 0.5, count: 12), b: [Float](repeating: 0.5, count: 12))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).fits")
        try ImageProcessing.saveFITS(img, to: url, object: "Nebulosa de Orión 猎户座 'x'")
        let data = try Data(contentsOf: url)
        let headerEnd = data.count - ((4 * 3 * 3 * 2 + 2879) / 2880) * 2880
        #expect(headerEnd > 0 && headerEnd % 2880 == 0)
        #expect(data.prefix(headerEnd).allSatisfy { $0 >= 32 && $0 < 127 })
        #expect(String(decoding: data.prefix(headerEnd), as: UTF8.self).contains("OBJECT  = 'Nebulosa de Orin  x'"))
    }
}
