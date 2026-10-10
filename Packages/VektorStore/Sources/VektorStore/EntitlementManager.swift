import AppKit
import Combine
import Foundation

/// Access is based exclusively on Apple's verified non-consumable purchases.
/// Starting the free trial records a zero-price purchase on the Apple Account;
/// reinstalling or clearing local preferences does not start another trial.
@MainActor
public final class EntitlementManager: ObservableObject {
    public static let shared = EntitlementManager(store: ApplePurchaseStore())
    public static let unlockProductID = "app.vektor.Vektor.unlock"
    public static let trialProductID = "app.vektor.Vektor.trial60"
    public static let trialDays = 60

    public enum AccessState: Equatable, Sendable {
        case checking
        case notStarted
        case trial
        case expired
        case purchased
    }

    @Published public private(set) var isPurchased = false
    @Published public private(set) var isTrialActive = false
    @Published public private(set) var product: StoreProduct?
    @Published public private(set) var trialProduct: StoreProduct?
    @Published public private(set) var isLoadingEntitlements = true
    @Published public private(set) var isLoadingProducts = false
    @Published public private(set) var purchaseInFlight = false
    @Published public private(set) var restoreInFlight = false
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var trialDaysRemaining = 0
    @Published public private(set) var trialEndsAt: Date?
    @Published public private(set) var hasStartedTrial = false

    private let store: any PurchaseStore
    private let now: () -> Date
    private let automaticallyRefreshes: Bool
    private var hasCheckedEntitlements = false
    private var currentTransactions: [UInt64: StoreTransaction] = [:]
    private var entitlementRevision: UInt64 = 0
    private var entitlementRefreshTask: Task<Void, Never>?
    private var productLoadTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var trialTimer: Timer?
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false

    public init(store: any PurchaseStore, now: @escaping () -> Date = Date.init,
                automaticallyRefreshes: Bool = true) {
        self.store = store
        self.now = now
        self.automaticallyRefreshes = automaticallyRefreshes
    }

    deinit {
        updatesTask?.cancel()
        entitlementRefreshTask?.cancel()
        productLoadTask?.cancel()
        trialTimer?.invalidate()
        for (center, observer) in lifecycleObservers { center.removeObserver(observer) }
    }

    public var accessState: AccessState {
        if !hasCheckedEntitlements { return .checking }
        if isPurchased { return .purchased }
        if isTrialActive { return .trial }
        return hasStartedTrial ? .expired : .notStarted
    }

    public var isUnlocked: Bool { accessState == .purchased || accessState == .trial }
    public var isBusy: Bool { purchaseInFlight || restoreInFlight }

    public var canStartTrial: Bool {
        hasCheckedEntitlements && !isLoadingEntitlements && !isBusy &&
        !isPurchased && !hasStartedTrial && product != nil && trialProduct != nil
    }

    public var statusText: String {
        switch accessState {
        case .checking: return "Checking purchases…"
        case .notStarted: return "Your 60-day free trial is ready to start"
        case .trial:
            return "Free trial — \(trialDaysRemaining) day\(trialDaysRemaining == 1 ? "" : "s") left"
        case .expired: return "Trial ended"
        case .purchased: return "Purchased — thank you!"
        }
    }

    /// Start the update listener before any asynchronous catalog/history work.
    /// Calling this repeatedly is safe; it never starts a trial automatically.
    public func start() {
        guard !started else { refresh(); return }
        started = true
        let updates = store.updates()
        updatesTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self else { break }
                await self.handle(update)
            }
        }
        if automaticallyRefreshes { installLifecycleObservers() }
        refresh()
        Task { [weak self] in await self?.loadProduct() }
    }

    /// Recompute the clock synchronously, then refresh Apple's current answer.
    /// The panel may call this each time it opens, including after a long sleep.
    public func refresh() {
        recomputeTrial()
        Task { [weak self] in await self?.refreshPurchased() }
    }

    public func loadProduct() async {
        if let task = productLoadTask { await task.value; return }
        isLoadingProducts = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performProductLoad()
            self.isLoadingProducts = false
            self.productLoadTask = nil
        }
        productLoadTask = task
        await task.value
    }

    private func performProductLoad() async {
        do {
            let catalog = try await store.products(for: [Self.unlockProductID, Self.trialProductID])
            let unlock = catalog.first { $0.id == Self.unlockProductID }
            let trial = catalog.first { $0.id == Self.trialProductID }
            product = unlock.flatMap {
                $0.type == .nonConsumable && $0.price > 0 &&
                !$0.displayPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0 : nil
            }
            trialProduct = trial.flatMap { $0.type == .nonConsumable && $0.price == 0 ? $0 : nil }
            if product == nil {
                lastErrorMessage = "The unlock price is unavailable. Check your connection and try again."
            } else if trialProduct == nil {
                lastErrorMessage = "The free trial is unavailable. Please try again."
            } else if !isBusy {
                lastErrorMessage = nil
            }
        } catch {
            product = nil
            trialProduct = nil
            lastErrorMessage = "Couldn’t load purchases. \(error.localizedDescription)"
        }
    }

    /// Coalesces overlapping refreshes. A purchase/update advances the revision
    /// so an older in-flight snapshot can never overwrite newer access state.
    public func refreshPurchased() async {
        if let task = entitlementRefreshTask { await task.value; return }
        isLoadingEntitlements = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performEntitlementRefresh()
            self.isLoadingEntitlements = false
            self.entitlementRefreshTask = nil
        }
        entitlementRefreshTask = task
        await task.value
    }

    private func performEntitlementRefresh() async {
        while !Task.isCancelled {
            let revision = entitlementRevision
            do {
                let snapshot = try await store.currentEntitlements()
                guard revision == entitlementRevision else { continue }
                var verified: [UInt64: StoreTransaction] = [:]
                var verificationFailed = false
                for result in snapshot {
                    switch result {
                    case .verified(let transaction):
                        if Self.isRelevant(transaction.productID), transaction.revocationDate == nil {
                            verified[transaction.id] = transaction
                        }
                    case .unverified(let productID, _):
                        if productID == nil || Self.isRelevant(productID!) { verificationFailed = true }
                    }
                }
                currentTransactions = verified
                hasCheckedEntitlements = true
                applyEntitlements()
                if verificationFailed {
                    lastErrorMessage = "Apple couldn’t verify a purchase. Try restoring your purchases."
                }
                return
            } catch {
                guard revision == entitlementRevision else { continue }
                hasCheckedEntitlements = true
                recomputeTrial()
                lastErrorMessage = "Couldn’t check purchases. \(error.localizedDescription)"
                return
            }
        }
    }

    @discardableResult
    public func purchase() async -> Bool {
        guard !isBusy else { return false }
        if isPurchased { return true }
        guard product != nil else {
            lastErrorMessage = "The unlock price is unavailable. Check your connection and try again."
            return false
        }
        return await purchaseProduct(Self.unlockProductID)
    }

    @discardableResult
    public func startTrial() async -> Bool {
        guard !isBusy else { return false }
        guard hasCheckedEntitlements, !isLoadingEntitlements else {
            lastErrorMessage = "Please wait while Vektor checks your purchases."
            return false
        }
        guard !isPurchased, !hasStartedTrial else {
            lastErrorMessage = hasStartedTrial ? "This Apple Account has already started the free trial." : nil
            return false
        }
        // The paywall must be able to disclose the actual localized unlock
        // price before the user confirms the free, non-renewing trial.
        guard product != nil, trialProduct != nil else {
            lastErrorMessage = "The trial and unlock price must load before starting. Please try again."
            return false
        }
        return await purchaseProduct(Self.trialProductID)
    }

    private func purchaseProduct(_ productID: String) async -> Bool {
        lastErrorMessage = nil
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            switch try await store.purchase(productID: productID) {
            case .success(let verification):
                let accepted = await handle(verification, expectedProductID: productID)
                return accepted && (productID == Self.unlockProductID ? isPurchased : isTrialActive)
            case .userCancelled:
                return false
            case .pending:
                lastErrorMessage = "Purchase pending approval. Vektor will update when Apple approves it."
                return false
            }
        } catch {
            if !Self.isCancellation(error) { lastErrorMessage = "Purchase failed. \(error.localizedDescription)" }
            return false
        }
    }

    public func restore() async {
        guard !isBusy else { return }
        lastErrorMessage = nil
        restoreInFlight = true
        defer { restoreInFlight = false }
        do {
            try await store.synchronize()
        } catch {
            if !Self.isCancellation(error) { lastErrorMessage = "Couldn’t restore purchases. \(error.localizedDescription)" }
            return
        }
        await refreshPurchased()
        if lastErrorMessage == nil, !isPurchased, !hasStartedTrial {
            lastErrorMessage = "No previous purchase or trial was found on this Apple Account."
        }
    }

    @discardableResult
    private func handle(_ result: StoreVerification, expectedProductID: String? = nil) async -> Bool {
        switch result {
        case .unverified(let productID, _):
            if expectedProductID != nil || productID == nil || Self.isRelevant(productID!) {
                lastErrorMessage = "Apple couldn’t verify this purchase. Try restoring your purchases."
            }
            return false
        case .verified(let transaction):
            guard Self.isRelevant(transaction.productID),
                  expectedProductID == nil || transaction.productID == expectedProductID else { return false }
            entitlementRevision &+= 1
            if transaction.revocationDate == nil {
                currentTransactions[transaction.id] = transaction
            } else {
                currentTransactions.removeValue(forKey: transaction.id)
            }
            hasCheckedEntitlements = true
            applyEntitlements()
            lastErrorMessage = nil
            // Access is delivered before finishing. Unverified/unrelated
            // transactions never reach finish.
            await store.finish(transactionID: transaction.id)
            await refreshPurchased()
            return transaction.revocationDate == nil
        }
    }

    private func applyEntitlements() {
        isPurchased = currentTransactions.values.contains {
            $0.productID == Self.unlockProductID && $0.revocationDate == nil
        }
        let trialStart = currentTransactions.values
            .filter { $0.productID == Self.trialProductID && $0.revocationDate == nil }
            .map(\.originalPurchaseDate).min()
        hasStartedTrial = trialStart != nil
        trialEndsAt = trialStart?.addingTimeInterval(Double(Self.trialDays) * 86_400)
        recomputeTrial()
    }

    private func recomputeTrial() {
        let remaining = trialEndsAt?.timeIntervalSince(now()) ?? 0
        isTrialActive = hasStartedTrial && remaining > 0
        trialDaysRemaining = remaining > 0
            ? Int(min(Double(Self.trialDays), ceil(remaining / 86_400))) : 0
        scheduleTrialTimer()
    }

    private func scheduleTrialTimer() {
        trialTimer?.invalidate()
        trialTimer = nil
        guard started, automaticallyRefreshes, !isPurchased, isTrialActive,
              let trialEndsAt else { return }
        let delay = min(60, max(0.01, trialEndsAt.timeIntervalSince(now())))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recomputeTrial() }
        }
        trialTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installLifecycleObservers() {
        let sources: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didBecomeActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ]
        for (center, name) in sources {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            lifecycleObservers.append((center, observer))
        }
    }

    private static func isRelevant(_ productID: String) -> Bool {
        productID == unlockProductID || productID == trialProductID
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? PurchaseStoreError) == .cancelled
    }
}
