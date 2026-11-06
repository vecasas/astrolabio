import Foundation
import Network

/// Fotograma recibido del puerto de imagen.
struct RawFrame {
    enum Kind { case preview, stacked }
    let kind: Kind
    let width: Int
    let height: Int
    /// Datos de 16 bits: Bayer GRBG (1 canal) en la vista previa, RGB entrelazado en el apilado.
    let pixels: [UInt16]
    let channels: Int
    let received = Date()
}

/// Canal de imagen del Seestar (TCP 4800). Cada mensaje es una cabecera binaria de 80 bytes
/// seguida de `size` bytes de datos. En la cabecera (big-endian): tamaño en los bytes 6–9,
/// identificador en el byte 15 y ancho y alto en los bytes 16–19.
/// - id 21: fotograma de vista previa (Bayer GRBG de 16 bits)
/// - id 23: imagen apilada, un ZIP con `raw_data` (RGB de 16 bits)
final class ImageStream {
    static let port: UInt16 = 4800

    var onFrame: ((RawFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Se llama (en el hilo principal) cada vez que el canal queda listo, también tras reconectar.
    var onReady: (() -> Void)?

    private let queue = DispatchQueue(label: "seestar.imaging", qos: .userInitiated)
    private var connection: NWConnection?
    private var buffer = Data()
    private var heartbeat: DispatchSourceTimer?
    private(set) var host = ""
    private(set) var isReady = false
    /// true mientras el usuario quiere el canal abierto: si se cae, se reconecta solo.
    private var wantConnected = false
    private var reconnectWork: DispatchWorkItem?

    func connect(host: String) {
        queue.async { [self] in
            // Ya abierto (o abriéndose) hacia el mismo telescopio: no hace falta repetir.
            if wantConnected && self.host == host && connection != nil { return }
            wantConnected = true
            openLocked(host: host)
        }
    }

    private func openLocked(host: String) {
            stopLocked()
            self.host = host
            guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            connection = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    self.status(tr("Canal de imagen conectado"))
                    self.receive()
                    self.startHeartbeat()
                    let cb = self.onReady
                    DispatchQueue.main.async { cb?() }
                case .failed(let e):
                    self.isReady = false
                    self.status(tr("Canal de imagen: %@", "\(e.localizedDescription)"))
                    self.scheduleReconnectLocked()
                case .waiting(let e):
                    self.status(tr("Canal de imagen esperando: %@", "\(e.localizedDescription)"))
                case .cancelled:
                    self.isReady = false
                default: break
                }
            }
            conn.start(queue: queue)
    }

    func disconnect() {
        queue.async { [self] in
            wantConnected = false
            stopLocked()
        }
    }

    /// Si el canal se cae, vuelve a abrirlo a los pocos segundos.
    private func scheduleReconnectLocked() {
        guard wantConnected, !host.isEmpty else { return }
        reconnectWork?.cancel()
        let target = host
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantConnected, !self.isReady else { return }
            self.status(tr("Reconectando el canal de imagen…"))
            self.openLocked(host: target)
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func stopLocked() {
        reconnectWork?.cancel()
        reconnectWork = nil
        heartbeat?.cancel()
        heartbeat = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        isReady = false
    }

    func requestStackedImage() { sendLine(#"{"id": 23, "method": "get_stacked_img"}"#) }
    func startPreview() { sendLine(#"{"id": 21, "method": "begin_streaming"}"#) }
    func stopPreview() { sendLine(#"{"id": 22, "method": "stop_streaming"}"#) }

    private func sendLine(_ text: String) {
        queue.async { [self] in
            // Si el canal está caído, se reabre; la petición se repite al quedar listo (onReady).
            if wantConnected && (connection == nil || !isReady) && !host.isEmpty && reconnectWork == nil {
                scheduleReconnectLocked()
            }
            connection?.send(content: Data((text + "\r\n").utf8), completion: .contentProcessed { _ in })
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            self?.connection?.send(content: Data((#"{"id": 2, "method": "test_connection"}"# + "\r\n").utf8),
                                   completion: .contentProcessed { _ in })
        }
        t.resume()
        heartbeat = t
    }

    private func status(_ text: String) {
        let cb = onStatus
        DispatchQueue.main.async { cb?(text) }
    }

    private func receive() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1024 * 1024) { [weak self] data, _, done, error in
            guard let self, self.connection === conn else { return }
            if let data { self.buffer.append(data); self.parse() }
            if error != nil || done {
                self.isReady = false
                self.status(tr("Canal de imagen cerrado; reconectando…"))
                self.scheduleReconnectLocked()
                return
            }
            self.receive()
        }
    }

    private func parse() {
        while buffer.count >= 80 {
            let h = [UInt8](buffer.prefix(80))
            let size = Int(UInt32(h[6]) << 24 | UInt32(h[7]) << 16 | UInt32(h[8]) << 8 | UInt32(h[9]))
            let id = Int(h[15])
            let width = Int(UInt16(h[16]) << 8 | UInt16(h[17]))
            let height = Int(UInt16(h[18]) << 8 | UInt16(h[19]))
            // Protección: un tamaño absurdo indica que hemos perdido la sincronía.
            if size > 200 * 1024 * 1024 { buffer.removeAll(); return }
            guard buffer.count >= 80 + size else { return }
            let start = buffer.startIndex + 80
            let payload = buffer.subdata(in: start..<(start + size))
            buffer.removeSubrange(buffer.startIndex..<(start + size))
            if size < 1000 { continue }
            handle(id: id, width: width, height: height, payload: payload)
        }
    }

    private func handle(id: Int, width: Int, height: Int, payload: Data) {
        let w = width > 0 ? width : 1080
        let h = height > 0 ? height : 1920
        var frame: RawFrame?
        switch id {
        case 21:
            if payload.count == w * h * 2 {
                frame = RawFrame(kind: .preview, width: w, height: h, pixels: Self.u16(payload), channels: 1)
            } else if payload.count == w * h * 6 {
                frame = RawFrame(kind: .preview, width: w, height: h, pixels: Self.u16(payload), channels: 3)
            }
        case 23:
            guard let raw = ZipReader.extract("raw_data", from: payload) else {
                status(tr("No se pudo descomprimir la imagen apilada"))
                return
            }
            if raw.count == w * h * 6 {
                frame = RawFrame(kind: .stacked, width: w, height: h, pixels: Self.u16(raw), channels: 3)
            } else if raw.count == w * h * 2 {
                frame = RawFrame(kind: .stacked, width: w, height: h, pixels: Self.u16(raw), channels: 1)
            } else {
                status(tr("Tamaño de imagen inesperado: %@ bytes", "\(raw.count)"))
            }
        default:
            return
        }
        if let frame {
            let cb = onFrame
            DispatchQueue.main.async { cb?(frame) }
        }
    }

    /// Los datos de píxel vienen en little-endian.
    private static func u16(_ data: Data) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: data.count / 2)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        for i in out.indices { out[i] = UInt16(littleEndian: out[i]) }
        return out
    }
}
