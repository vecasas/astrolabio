import Foundation
import Combine
import CoreGraphics

/// Vista en directo: recibe fotogramas del canal de imagen, los procesa fuera del hilo
/// principal y publica la imagen estirada.
@MainActor
final class LiveViewModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var info = tr("Sin imagen")
    @Published private(set) var streamStatus = ""
    @Published private(set) var isProcessing = false
    @Published var options = ProcessingOptions() { didSet { if options != oldValue { rerender() } } }
    @Published var autoRefresh = true
    @Published private(set) var isPreviewing = false

    private let stream = ImageStream()
    private var linear: LinearImage?
    private var lastFrameKind: RawFrame.Kind?
    private var lastRequest = Date.distantPast
    private var renderGeneration = 0
    private var listenerID: UUID?
    private var pollTask: Task<Void, Never>?
    private var statusSink: AnyCancellable?
    private var streamHost = ""

    init() {
        stream.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame) }
        }
        stream.onStatus = { [weak self] text in
            MainActor.assumeIsolated { self?.streamStatus = text }
        }
        // Nada más abrirse (o reabrirse) el canal, pide la última imagen apilada.
        stream.onReady = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isPreviewing { self.stream.startPreview() }
                if self.autoRefresh { self.requestStacked() }
            }
        }
    }

    func attach(to client: SeestarClient) {
        if let id = listenerID { client.removeListener(id) }
        listenerID = client.addListener { [weak self] event in
            guard let self, self.autoRefresh, event.name == "Stack" else { return }
            // Cada vez que el telescopio añade fotogramas pedimos la imagen apilada (como mucho cada 8 s).
            if Date().timeIntervalSince(self.lastRequest) > 8 { self.requestStacked() }
        }
        // Si el control se reconecta solo (o se conecta desde otro sitio), abre también el canal de imagen.
        statusSink = client.$status
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] status in
                MainActor.assumeIsolated {
                    guard let self, let client, status == .connected, !client.host.isEmpty else { return }
                    if self.streamHost != client.host || !self.stream.isReady { self.connect(host: client.host) }
                }
            }
    }

    func connect(host: String) {
        streamHost = host
        stream.connect(host: host)
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                if self.autoRefresh && Date().timeIntervalSince(self.lastRequest) > 20 { self.requestStacked() }
            }
        }
    }

    func disconnect() {
        streamHost = ""
        isPreviewing = false
        pollTask?.cancel()
        stream.disconnect()
    }

    func requestStacked() {
        lastRequest = Date()
        stream.requestStackedImage()
    }

    func startPreview() { stream.startPreview(); isPreviewing = true }
    func stopPreview() { stream.stopPreview(); isPreviewing = false }

    private func handle(_ frame: RawFrame) {
        lastFrameKind = frame.kind
        let kindText = frame.kind == .stacked ? tr("Apilado") : tr("Vista previa")
        info = "\(kindText) · \(frame.width)×\(frame.height) · \(frame.received.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: Loc.shared.locale)))"
        isProcessing = true
        let opts = options
        renderGeneration += 1
        let gen = renderGeneration
        Task.detached(priority: .userInitiated) {
            let lin = ImageProcessing.linear(from: frame)
            let img = ImageProcessing.render(lin, options: opts)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.linear = lin
                if gen == self.renderGeneration { self.image = img; self.isProcessing = false }
            }
        }
    }

    private func rerender() {
        guard let lin = linear else { return }
        isProcessing = true
        let opts = options
        renderGeneration += 1
        let gen = renderGeneration
        Task.detached(priority: .userInitiated) {
            let img = ImageProcessing.render(lin, options: opts)
            await MainActor.run { [weak self] in
                guard let self, gen == self.renderGeneration else { return }
                self.image = img
                self.isProcessing = false
            }
        }
    }

    /// Guarda la imagen procesada (PNG) y los datos lineales (FITS) en la carpeta elegida.
    func save(to folder: URL, name: String) throws -> [URL] {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safe = name.isEmpty ? "Seestar" : name.replacingOccurrences(of: "/", with: "-")
        var saved: [URL] = []
        if let image {
            let png = folder.appendingPathComponent("\(safe)_\(stamp).png")
            try ImageProcessing.savePNG(image, to: png)
            saved.append(png)
        }
        if let linear {
            let fits = folder.appendingPathComponent("\(safe)_\(stamp).fits")
            try ImageProcessing.saveFITS(linear, to: fits, object: safe)
            saved.append(fits)
        }
        return saved
    }
}
