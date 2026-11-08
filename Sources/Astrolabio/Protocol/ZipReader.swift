import Foundation
import Compression

/// Lector ZIP mínimo: el Seestar envía la imagen apilada dentro de un ZIP con un único
/// archivo `raw_data`. Solo soporta entradas sin comprimir (stored) o con deflate.
enum ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    static func entries(in data: Data) -> [Entry] {
        let b = [UInt8](data)
        // Busca el registro de fin de directorio central desde el final.
        guard b.count >= 22 else { return [] }
        var eocd = -1
        var i = b.count - 22
        let minI = max(0, b.count - 22 - 65_535)
        while i >= minI {
            if b[i] == 0x50 && b[i + 1] == 0x4B && b[i + 2] == 0x05 && b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return localScan(b) }
        let count = Int(u16(b, eocd + 10))
        var offset = Int(u32(b, eocd + 16))
        var result: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= b.count, u32(b, offset) == 0x02014B50 else { break }
            let method = u16(b, offset + 10)
            let csize = Int(u32(b, offset + 20))
            let usize = Int(u32(b, offset + 24))
            let nameLen = Int(u16(b, offset + 28))
            let extraLen = Int(u16(b, offset + 30))
            let commentLen = Int(u16(b, offset + 32))
            let local = Int(u32(b, offset + 42))
            guard offset + 46 + nameLen <= b.count else { break }
            let name = String(decoding: b[(offset + 46)..<(offset + 46 + nameLen)], as: UTF8.self)
            result.append(Entry(name: name, method: method, compressedSize: csize,
                                uncompressedSize: usize, localHeaderOffset: local))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return result
    }

    /// Por si falta el directorio central: lee las cabeceras locales.
    private static func localScan(_ b: [UInt8]) -> [Entry] {
        guard b.count >= 30, u32(b, 0) == 0x04034B50 else { return [] }
        let method = u16(b, 8)
        let csize = Int(u32(b, 18))
        let usize = Int(u32(b, 22))
        let nameLen = Int(u16(b, 26))
        guard 30 + nameLen <= b.count else { return [] }
        let name = String(decoding: b[30..<(30 + nameLen)], as: UTF8.self)
        return [Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: 0)]
    }

    static func extract(_ name: String, from data: Data) -> Data? {
        let list = entries(in: data)
        guard let entry = list.first(where: { $0.name == name }) ?? list.first else { return nil }
        let b = data
        let base = b.startIndex
        let lh = entry.localHeaderOffset
        guard lh + 30 <= b.count else { return nil }
        let bytes = [UInt8](b[(base + lh)..<(base + lh + 30)])
        guard u32(bytes, 0) == 0x04034B50 else { return nil }
        let nameLen = Int(u16(bytes, 26))
        let extraLen = Int(u16(bytes, 28))
        let start = lh + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= b.count else { return nil }
        let payload = b.subdata(in: (base + start)..<(base + start + entry.compressedSize))
        switch entry.method {
        case 0: return payload
        case 8: return inflate(payload, expectedSize: entry.uncompressedSize)
        default: return nil
        }
    }

    /// Descomprime deflate "en bruto" (sin cabecera zlib), que es lo que usa ZIP.
    /// Tamaño máximo de una imagen descomprimida (un apilado de 4K a 16 bits y 3 canales ocupa unos 50 MB).
    static let maxUncompressed = 128 * 1024 * 1024

    static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        // El tamaño declarado viene del telescopio: se limita para que un ZIP manipulado no
        // obligue a reservar gigas de memoria (bomba de descompresión).
        guard expectedSize >= 0, expectedSize <= maxUncompressed else { return nil }
        let capacity = min(maxUncompressed, max(expectedSize, data.count * 4) + 1024)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}
