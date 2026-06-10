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
/// ourselves: the start date lives in `UserDefaults` AND the Keychain, and the
/// two are cross-checked on every launch with the EARLIEST plausible stamp
/// winning. The Keychain copy survives app delete/reinstall and `defaults
/// delete`, so neither reinstalling nor clearing/editing UserDefaults resets
/// or extends the trial (see `loadOrStartTrial`).
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
        let now = Date().timeIntervalSince1970
        let storedDefaults = defaults.double(forKey: trialDefaultsKey)

        // Read the Keychain copy whenever there is any sign one exists.
        // Two deliberate departures from the old logic:
        //   1. When UserDefaults is EMPTY we read the Keychain
        //      unconditionally — the presence flag lives in UserDefaults
        //      too, so `defaults delete` wipes both, and trusting the
        //      flag here was exactly the one-command trial reset.
        //   2. When UserDefaults HAS a value we still cross-check the
        //      Keychain (flag permitting) so a hand-edited future epoch
        //      can't extend the trial.
        // Cost: one Keychain read per launch once a trial stamp exists.
        // In production-signed builds this is silent; in dev ad-hoc
        // builds it may prompt after a signature change — acceptable,
        // it's the trial stamp, not a first-run UX path.
        var keychainEpoch: Double = 0
        if storedDefaults <= 0 || KeychainStorage.hasKey(trialKeychainKey) {
            if let s = KeychainStorage.get(trialKeychainKey),
               let e = Double(s), e > 0 {
                keychainEpoch = e
            }
        }

        // Earliest plausible stamp wins. Future-dated values are
        // tampered/corrupt — a legitimate stamp is never in the future.
        let candidates = [storedDefaults, keychainEpoch].filter { $0 > 0 && $0 <= now }
        if let epoch = candidates.min() {
            // Heal whichever store disagrees. The Keychain is only ever
            // overwritten with an EQUAL-OR-EARLIER epoch — never reset
            // forward to "now" while a stamp exists.
            if storedDefaults != epoch { defaults.set(epoch, forKey: trialDefaultsKey) }
            if keychainEpoch != epoch { KeychainStorage.set(String(epoch), for: trialKeychainKey) }
            return Date(timeIntervalSince1970: epoch)
        }

        // Genuine first launch — stamp "now" into both stores.
        defaults.set(now, forKey: trialDefaultsKey)
        KeychainStorage.set(String(now), for: trialKeychainKey)
        return Date(timeIntervalSince1970: now)
    }
}
