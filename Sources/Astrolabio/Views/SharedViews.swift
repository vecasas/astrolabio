import SwiftUI
import ImageIO

// Componentes compartidos que antes vivían en LiveView.swift y AlbumView.swift.

@MainActor
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// Imagen apilada a pantalla completa para enseñarla a otras personas.
@MainActor
struct StarPartyView: View {
    @EnvironmentObject var live: LiveViewModel
    @EnvironmentObject var client: SeestarClient

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            if let img = live.image {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(tr("Esperando imagen…")).foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading) {
                Text(name).font(.largeTitle.bold())
                Text(tr("%@ fotogramas", "\(client.stackedFrames)")).font(.title3)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(24)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var name: String {
        (client.lastEvents["AutoGoto"]?.data["target_name"] as? String) ?? ""
    }
}

/// Imagen descargada por HTTP. El servidor del Seestar envía los JPEG como
/// «application/octet-stream», así que se descodifican a mano con ImageIO (y se guardan en caché).
struct RemoteImage: View {
    let url: URL
    var contentMode: ContentMode = .fit
    var loadingText: String? = nil
    @State private var image: CGImage?
    @State private var failed = false

    private static let cache = NSCache<NSURL, CGImageBox>()
    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    Text(tr("No se pudo cargar")).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                    if let loadingText { Text(loadingText).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let hit = Self.cache.object(forKey: url as NSURL) { image = hit.image; return }
        failed = false
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { failed = true; return }
            let decoded = await Task.detached { () -> CGImage? in
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }.value
            if let decoded {
                Self.cache.setObject(CGImageBox(decoded), forKey: url as NSURL)
                image = decoded
            } else { failed = true }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
