import Foundation

/// Vigila el telescopio cada minuto: avisa (en el Mac y al móvil) de batería baja, memoria casi
/// llena o un telescopio que deja de responder durante el plan, y retoma un plan interrumpido
/// por un reinicio en cuanto vuelve la conexión.
@MainActor
final class HealthMonitor {
    static let lowBattery = 20
    static let lowStorageMB = 1000.0
    static let silentAfter: TimeInterval = 180

    private var limiter = AlertLimiter(interval: 1800)
    private var task: Task<Void, Never>?
    private var disconnectedSince: Date?
    private var lastDeviceRefresh = Date.distantPast
    private var resumeChecked = false

    func start(client: SeestarClient, settings: AppSettings, runner: SessionRunner, plan: PlanStore, nightGuard: NightGuard? = nil) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(client: client, settings: settings, runner: runner, plan: plan)
                await nightGuard?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func tick(client: SeestarClient, settings: AppSettings, runner: SessionRunner, plan: PlanStore) async {
        // Retomar un plan que se cortó por un cierre de la app o un reinicio del ordenador.
        if !resumeChecked && client.isConnected {
            resumeChecked = true
            if !runner.isRunning, let saved = SessionRunner.pendingResume(),
               plan.items.contains(where: { $0.status == .pending || $0.status == .running }) {
                runner.start(client: client, settings: settings, plan: plan, resuming: saved)
            }
        }

        let issues = Self.issues(connected: client.isConnected, battery: client.battery,
                                 charging: client.chargerStatus == "Charging",
                                 freeMB: client.freeStorageMB, planRunning: runner.isRunning,
                                 disconnectedFor: disconnectedSince.map { Date().timeIntervalSince($0) } ?? 0)
        if client.isConnected {
            disconnectedSince = nil
            if Date().timeIntervalSince(lastDeviceRefresh) > 600 {
                lastDeviceRefresh = Date()
                await client.refreshDeviceState()
            }
        } else if disconnectedSince == nil {
            disconnectedSince = Date()
        }
        guard settings.healthAlerts else { return }
        for issue in issues where limiter.shouldSend(issue.kind) {
            client.addLog(issue.message, .warning)
            settings.notify("Astrolabio", issue.message)
        }
    }

    struct Issue: Equatable {
        let kind: String
        let message: String
    }

    /// Problemas que merecen un aviso (función pura, para las pruebas).
    static func issues(connected: Bool, battery: Int?, charging: Bool, freeMB: Double?,
                       planRunning: Bool, disconnectedFor: TimeInterval) -> [Issue] {
        var out: [Issue] = []
        if connected {
            if let b = battery, b <= lowBattery, !charging {
                out.append(Issue(kind: "battery", message: tr("⚠️ Batería del Seestar baja: %@ %%.", "\(b)")))
            }
            if let f = freeMB, f < lowStorageMB {
                out.append(Issue(kind: "storage", message: tr("⚠️ Queda poco espacio en el Seestar: %@ MB.", "\(Int(f))")))
            }
        } else if planRunning && disconnectedFor >= silentAfter {
            out.append(Issue(kind: "silent", message: tr("⚠️ El Seestar no responde desde hace %@ min y hay un plan en marcha.",
                                                        "\(Int(disconnectedFor / 60))")))
        }
        return out
    }
}
