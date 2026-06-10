import Foundation
import StoreKit
import os

/// Monetisation for Vektor: a single non-consumable unlock (`Vektor Lifetime
/// Unlock`) gated behind a self-managed 7-day free trial. The whole app is the
/// product — during the trial everything works; once it lapses (and nothing is
/// purchased) `PanelRootView` shows the blocking paywall.
///
/// **Why a self-managed trial.** The App Store only offers built-in free trials
/// for auto-renewable subscriptions. For a one-time purchase we track the trial
/// ourselves: the start date lives in `UserDefaults` (read on every launch — no
/// Keychain prompt) and is mirrored into the Keychain, which survives an app
/// delete/reinstall, so the trial can't be reset by reinstalling. The Keychain
/// is read **only** when `UserDefaults` has lost the value (fresh install /
/// cleared defaults); checking the presence flag first keeps the macOS "wants to
/// use confidential information" prompt off the normal launch path (see
/// `KeychainStorage`).
@MainActor
final class EntitlementManager: ObservableObject {
    static let shared = EntitlementManager()

    /// Non-consumable IAP. Must match the product ID created in App Store
    /// Connect and the one in `Vektor.storekit`.
    static let unlockProductID = "app.vektor.Vektor.unlock"

    /// Length of the free trial, in days.
    static let trialDays = 7

    @Published private(set) var isPurchased = false
    @Published private(set) var product: Product?
    @Published private(set) var purchaseInFlight = false
    @Published private(set) var lastErrorMessage: String?
    /// Whole days left in the trial (ceil, clamped ≥ 0). Recomputed at launch
    /// and on `refresh()`; drives the trial banner and paywall copy.
    @Published private(set) var trialDaysRemaining = EntitlementManager.trialDays

    private let trialStart: Date
    private var updatesTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "app.vektor.Vektor", category: "iap")

    private static let trialDefaultsKey = "vektor.trial.startEpoch"
    private static let trialKeychainKey = "vektor.trial.start"

    private init() {
        self.trialStart = Self.loadOrStartTrial()
        recomputeTrial()
    }

    // MARK: - Derived state

    var trialEndsAt: Date { trialStart.addingTimeInterval(Double(Self.trialDays) * 86_400) }
    var isTrialActive: Bool { Date() < trialEndsAt }
    /// The gate: the app is usable if it's been bought OR the trial is live.
    var isUnlocked: Bool { isPurchased || isTrialActive }

    var statusText: String {
        if isPurchased { return "Purchased — thank you!" }
        if isTrialActive {
            return "Free trial — \(trialDaysRemaining) day\(trialDaysRemaining == 1 ? "" : "s") left"
        }
        return "Trial ended"
    }

    private func recomputeTrial() {
        trialDaysRemaining = max(0, Int(ceil(trialEndsAt.timeIntervalSinceNow / 86_400)))
    }

    // MARK: - Lifecycle

    /// Call once at launch (from `AppDelegate`). Loads the product, restores any
    /// prior purchase, and listens for out-of-band transaction updates
    /// (renewals, refunds, Ask-to-Buy approvals, purchases on other devices).
    func start() {
        recomputeTrial()
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await loadProduct() }
        Task { await refreshPurchased() }
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.unlockProductID])
            product = products.first
            if products.isEmpty {
                Self.logger.warning("No IAP product for \(Self.unlockProductID) — not configured in App Store Connect / Vektor.storekit yet")
            }
        } catch {
            Self.logger.error("loadProduct failed: \(error.localizedDescription)")
        }
    }

    /// Reflect StoreKit's source of truth into `isPurchased`.
    func refreshPurchased() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result,
               txn.productID == Self.unlockProductID,
               txn.revocationDate == nil {
                owned = true
            }
        }
        isPurchased = owned
    }

    @discardableResult
    func purchase() async -> Bool {
        guard let product else {
            lastErrorMessage = "Product unavailable — check your connection and try again."
            return false
        }
        lastErrorMessage = nil
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
                return isPurchased
            case .userCancelled:
                return false
            case .pending:
                lastErrorMessage = "Purchase pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            Self.logger.error("purchase failed: \(error.localizedDescription)")
            return false
        }
    }

    func restore() async {
        lastErrorMessage = nil
        do {
            try await AppStore.sync()
        } catch {
            // `AppStore.sync()` throws on cancel too; only surface real failures.
            Self.logger.notice("AppStore.sync ended: \(error.localizedDescription)")
        }
        await refreshPurchased()
        if !isPurchased { lastErrorMessage = "No previous purchase found on this Apple ID." }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let txn) = result else {
            Self.logger.warning("unverified transaction ignored")
            return
        }
        if txn.productID == Self.unlockProductID, txn.revocationDate == nil {
            isPurchased = true
        } else if txn.productID == Self.unlockProductID, txn.revocationDate != nil {
            isPurchased = false
        }
        await txn.finish()
    }

    // MARK: - Trial persistence (UserDefaults primary, Keychain reinstall-proof)

    private static func loadOrStartTrial() -> Date {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: trialDefaultsKey)
        if stored > 0 { return Date(timeIntervalSince1970: stored) }

        // UserDefaults lost it (fresh install / cleared). Recover from the
        // Keychain if present — checking the presence flag first avoids a
        // Keychain *read* (and its signature-change prompt) on first run.
        if KeychainStorage.hasKey(trialKeychainKey),
           let s = KeychainStorage.get(trialKeychainKey),
           let epoch = Double(s), epoch > 0 {
            defaults.set(epoch, forKey: trialDefaultsKey)
            return Date(timeIntervalSince1970: epoch)
        }

        // Genuine first launch — stamp "now" into both stores.
        let now = Date().timeIntervalSince1970
        defaults.set(now, forKey: trialDefaultsKey)
        KeychainStorage.set(String(now), for: trialKeychainKey)
        return Date(timeIntervalSince1970: now)
    }
}
