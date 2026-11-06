import Foundation

/// Estado del cielo compartido por toda la app: previsión de Open-Meteo para el lugar de
/// observación (se refresca cada 30 minutos) y datos derivados como la temperatura actual.
@MainActor
final class SkyStore: ObservableObject {
    @Published private(set) var hours: [WeatherHour] = []
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var error: String?

    private var lastLocation: (Double, Double)?
    private var task: Task<Void, Never>?

    /// Empieza a refrescar la previsión periódicamente para la ubicación indicada.
    func start(lat: Double, lon: Double) {
        if let l = lastLocation, abs(l.0 - lat) < 1e-4, abs(l.1 - lon) < 1e-4, task != nil { return }
        lastLocation = (lat, lon)
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    func refresh() async {
        guard let (lat, lon) = lastLocation else { return }
        do {
            hours = try await WeatherService.forecast(lat: lat, lon: lon)
            lastUpdate = Date()
            error = nil
        } catch {
            self.error = tr("Sin previsión del tiempo")
        }
    }

    private func nearest(_ date: Date = Date()) -> WeatherHour? {
        hours.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) })
            .flatMap { abs($0.time.timeIntervalSince(date)) < 5400 ? $0 : nil }
    }

    var currentTemperature: Double? { nearest()?.temperature }
    var currentCloud: Double? { nearest()?.cloudCover }
    var currentHumidity: Double? { nearest()?.humidity }
    var currentDewPoint: Double? { nearest()?.dewPoint }
}
