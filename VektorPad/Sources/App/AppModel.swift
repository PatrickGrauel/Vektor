import SwiftUI
import VektorEngine
import os

/// Lean iOS app model. Owns the shared `NumiEngine` and keeps it fed with
/// live FX + crypto rates so currency conversions in the calculator work
/// out of the box. (The macOS app's model also drives METAR refresh jobs,
/// reachability, and Keychain-stored API keys — those come online with the
/// aviation / stocks panes in a later pass.)
@MainActor
final class AppModel: ObservableObject {
    @Published var engine: NumiEngine?
    @Published var engineError: String?
    @Published var fxSourceLabel: String = "Not configured"
    @Published var fxSnapshotDate: Date?
    @Published var fxCurrencyCount: Int = 0

    private static let logger = Logger(subsystem: "app.vektor.VektorPad", category: "app-model")
    private let fx = FXService()
    private let crypto = CryptoService()
    private var fxTask: Task<Void, Never>?
    private var cryptoTask: Task<Void, Never>?

    init() {
        do {
            self.engine = try NumiEngine()
        } catch {
            self.engineError = error.localizedDescription
        }
    }

    func bootstrapLiveData() async {
        // Frankfurter — free ECB rates, no API key required — so a fresh
        // install does live currency conversion without any setup.
        fxSourceLabel = "Frankfurter (ECB)"
        fxTask?.cancel()
        fxTask = Task { [weak self] in
            guard let self else { return }
            for await snap in await self.fx.snapshots(using: .frankfurter) {
                if Task.isCancelled { return }
                self.engine?.applyFX(snap)
                self.fxSnapshotDate = snap.timestamp
                self.fxCurrencyCount = snap.ratesPerUSD.count
                Self.logger.info("FX → engine: \(snap.ratesPerUSD.count) rates")
            }
        }

        cryptoTask?.cancel()
        cryptoTask = Task { [weak self] in
            guard let self else { return }
            for await snap in await self.crypto.snapshots() {
                if Task.isCancelled { return }
                self.engine?.applyCrypto(snap)
            }
        }
    }

    deinit {
        fxTask?.cancel()
        cryptoTask?.cancel()
    }
}
