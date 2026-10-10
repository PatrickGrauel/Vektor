import Foundation
import XCTest
@testable import VektorStore

@MainActor
final class EntitlementManagerTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testInitialAccessWaitsForVerifiedEntitlementRead() async {
        let store = FakePurchaseStore()
        store.suspendNextEntitlementRead = true
        let manager = EntitlementManager(store: store, now: { self.referenceDate }, automaticallyRefreshes: false)
        XCTAssertEqual(manager.accessState, .checking)
        XCTAssertTrue(manager.isLoadingEntitlements)
        XCTAssertFalse(manager.canStartTrial)

        let refresh = Task { await manager.refreshPurchased() }
        await waitUntil { store.entitlementContinuation != nil }
        XCTAssertEqual(manager.accessState, .checking)
        store.resumeEntitlements([.verified(unlockTransaction(at: referenceDate))])
        await refresh.value
        XCTAssertEqual(manager.accessState, .purchased)
        XCTAssertFalse(manager.isLoadingEntitlements)
    }

    func testFreshInstallDoesNotAutomaticallyStartTrial() async {
        let clock = TestClock(referenceDate)
        let store = FakePurchaseStore()
        let manager = await loadedManager(store: store, clock: clock)
        manager.start()
        await waitUntil { store.entitlementCalls >= 2 }

        XCTAssertEqual(manager.accessState, .notStarted)
        XCTAssertFalse(manager.hasStartedTrial)
        XCTAssertFalse(manager.isUnlocked)
        XCTAssertNil(manager.trialEndsAt)
        XCTAssertEqual(manager.trialDaysRemaining, 0)
        XCTAssertTrue(manager.canStartTrial)
        XCTAssertTrue(store.purchasedProductIDs.isEmpty)

        clock.now.addTimeInterval(90 * 86_400)
        manager.refresh()
        XCTAssertEqual(manager.accessState, .notStarted)
        XCTAssertTrue(store.purchasedProductIDs.isEmpty)
    }

    func testVerifiedTrialExpiresAtExactlySixtyDays() async {
        let clock = TestClock(referenceDate)
        let transaction = trialTransaction(at: clock.now)
        let store = FakePurchaseStore(entitlements: [.verified(transaction)])
        let manager = await loadedManager(store: store, clock: clock)
        let endsAt = referenceDate.addingTimeInterval(60 * 86_400)

        XCTAssertEqual(manager.accessState, .trial)
        XCTAssertTrue(manager.isUnlocked)
        XCTAssertTrue(manager.hasStartedTrial)
        XCTAssertEqual(manager.trialEndsAt, endsAt)
        XCTAssertEqual(manager.trialDaysRemaining, 60)

        clock.now = referenceDate.addingTimeInterval(0.5)
        manager.refresh()
        XCTAssertEqual(manager.trialDaysRemaining, 60)

        clock.now = endsAt.addingTimeInterval(-86_400)
        manager.refresh()
        XCTAssertEqual(manager.trialDaysRemaining, 1)

        clock.now = endsAt.addingTimeInterval(-0.5)
        manager.refresh()
        XCTAssertTrue(manager.isTrialActive)
        XCTAssertEqual(manager.trialDaysRemaining, 1)

        clock.now = endsAt
        manager.refresh()
        XCTAssertEqual(manager.accessState, .expired)
        XCTAssertFalse(manager.isUnlocked)
        XCTAssertFalse(manager.isTrialActive)
        XCTAssertEqual(manager.trialDaysRemaining, 0)
        XCTAssertFalse(manager.canStartTrial)

        clock.now = endsAt.addingTimeInterval(90 * 86_400)
        manager.refresh()
        XCTAssertEqual(manager.trialDaysRemaining, 0)
    }

    func testTrialPurchaseDateSurvivesReinstallationAndRestore() async {
        let clock = TestClock(referenceDate.addingTimeInterval(65 * 86_400))
        let originalTrial = trialTransaction(at: referenceDate)
        let store = FakePurchaseStore(entitlements: [.verified(originalTrial)])
        let manager = await loadedManager(store: store, clock: clock)
        XCTAssertEqual(manager.accessState, .expired)

        let reinstalled = await loadedManager(store: store, clock: clock)
        await reinstalled.restore()
        XCTAssertEqual(reinstalled.accessState, .expired)
        XCTAssertEqual(reinstalled.trialEndsAt, referenceDate.addingTimeInterval(60 * 86_400))
        XCTAssertFalse(reinstalled.canStartTrial)
        XCTAssertTrue(store.purchasedProductIDs.isEmpty)
        XCTAssertEqual(store.synchronizeCalls, 1)
    }

    func testRestoredPurchaseDateDoesNotResetOriginalTrialStart() async {
        let clock = TestClock(referenceDate.addingTimeInterval(65 * 86_400))
        let restoredTrial = StoreTransaction(id: 10, productID: EntitlementManager.trialProductID,
                                             purchaseDate: clock.now, originalPurchaseDate: referenceDate)
        let store = FakePurchaseStore(entitlements: [.verified(restoredTrial)])
        let manager = await loadedManager(store: store, clock: clock)
        XCTAssertEqual(manager.accessState, .expired)
        XCTAssertEqual(manager.trialEndsAt, referenceDate.addingTimeInterval(60 * 86_400))
        XCTAssertEqual(manager.trialDaysRemaining, 0)

        await manager.restore()
        XCTAssertEqual(manager.accessState, .expired)
        XCTAssertFalse(manager.canStartTrial)
        let relaunched = await loadedManager(store: store, clock: clock)
        XCTAssertEqual(relaunched.accessState, .expired)
        XCTAssertEqual(relaunched.trialEndsAt, referenceDate.addingTimeInterval(60 * 86_400))
        XCTAssertTrue(store.purchasedProductIDs.isEmpty)
    }

    func testClockBeforeVerifiedTrialPurchaseDoesNotShowMoreThanSixtyDays() async {
        let clock = TestClock(referenceDate)
        let store = FakePurchaseStore(entitlements: [
            .verified(trialTransaction(at: referenceDate.addingTimeInterval(86_400))),
        ])
        let manager = await loadedManager(store: store, clock: clock)
        XCTAssertEqual(manager.trialDaysRemaining, 60)
    }

    func testEarliestVerifiedTrialDateCannotBeExtendedByNewerTrialTransaction() async {
        let clock = TestClock(referenceDate.addingTimeInterval(90 * 86_400))
        let newerTrial = StoreTransaction(id: 99, productID: EntitlementManager.trialProductID,
                                         purchaseDate: clock.now)
        let store = FakePurchaseStore(entitlements: [
            .verified(trialTransaction(at: referenceDate)),
            .verified(newerTrial),
        ])
        let manager = await loadedManager(store: store, clock: clock)
        XCTAssertEqual(manager.accessState, .expired)
        XCTAssertEqual(manager.trialEndsAt, referenceDate.addingTimeInterval(60 * 86_400))
        XCTAssertFalse(manager.canStartTrial)
    }

    func testVerifiedLifetimeUnlockWinsOverExpiredTrialAndUnverifiedItems() async {
        let clock = TestClock(referenceDate.addingTimeInterval(90 * 86_400))
        let store = FakePurchaseStore(entitlements: [
            .verified(trialTransaction(at: referenceDate)),
            .unverified(productID: EntitlementManager.unlockProductID, message: "Invalid signature"),
            .verified(unlockTransaction(at: referenceDate)),
        ])
        let manager = await loadedManager(store: store, clock: clock)
        XCTAssertEqual(manager.accessState, .purchased)
        XCTAssertTrue(manager.isPurchased)
        XCTAssertTrue(manager.isUnlocked)
    }

    func testRevokedAndUnverifiedEntitlementsDoNotUnlock() async {
        let clock = TestClock(referenceDate.addingTimeInterval(90 * 86_400))
        let revoked = StoreTransaction(id: 3, productID: EntitlementManager.unlockProductID,
                                       purchaseDate: referenceDate, revocationDate: clock.now)
        let store = FakePurchaseStore(entitlements: [
            .verified(trialTransaction(at: referenceDate)),
            .verified(revoked),
            .unverified(productID: EntitlementManager.unlockProductID, message: "Invalid signature"),
        ])
        let manager = await loadedManager(store: store, clock: clock)
        XCTAssertEqual(manager.accessState, .expired)
        XCTAssertFalse(manager.isPurchased)
        XCTAssertFalse(manager.isUnlocked)
    }

    func testSuccessfulTrialPurchaseUsesVerifiedTransactionDateAndFinishesIt() async {
        let clock = TestClock(referenceDate)
        let transaction = trialTransaction(at: referenceDate)
        let store = FakePurchaseStore()
        store.purchaseResult = .success(.verified(transaction))
        let manager = await loadedManager(store: store, clock: clock)

        let succeeded = await manager.startTrial()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(manager.accessState, .trial)
        XCTAssertEqual(manager.trialEndsAt, referenceDate.addingTimeInterval(60 * 86_400))
        XCTAssertEqual(store.purchasedProductIDs, [EntitlementManager.trialProductID])
        XCTAssertEqual(store.finishedTransactionIDs, [transaction.id])
        XCTAssertFalse(manager.purchaseInFlight)
        XCTAssertFalse(manager.canStartTrial)
    }

    func testSuccessfulLifetimePurchaseFinishesVerifiedTransaction() async {
        let clock = TestClock(referenceDate)
        let transaction = unlockTransaction(at: referenceDate)
        let store = FakePurchaseStore()
        store.purchaseResult = .success(.verified(transaction))
        let manager = await loadedManager(store: store, clock: clock)

        let succeeded = await manager.purchase()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(manager.accessState, .purchased)
        XCTAssertEqual(store.purchasedProductIDs, [EntitlementManager.unlockProductID])
        XCTAssertEqual(store.finishedTransactionIDs, [transaction.id])
        XCTAssertFalse(manager.purchaseInFlight)
    }

    func testUnverifiedPurchaseDoesNotFinishOrGrantAccess() async {
        let store = FakePurchaseStore()
        store.purchaseResult = .success(.unverified(productID: EntitlementManager.unlockProductID,
                                                    message: "Invalid signature"))
        let manager = await loadedManager(store: store, clock: TestClock(referenceDate))
        let succeeded = await manager.purchase()
        XCTAssertFalse(succeeded)
        XCTAssertFalse(manager.isUnlocked)
        XCTAssertTrue(store.finishedTransactionIDs.isEmpty)
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertFalse(manager.purchaseInFlight)
    }

    func testCancelledPendingAndFailedPurchasesLeaveAccessLocked() async {
        let store = FakePurchaseStore()
        let manager = await loadedManager(store: store, clock: TestClock(referenceDate))

        store.purchaseResult = .userCancelled
        let cancelled = await manager.purchase()
        XCTAssertFalse(cancelled)
        XCTAssertNil(manager.lastErrorMessage)

        store.purchaseResult = .pending
        let pending = await manager.purchase()
        XCTAssertFalse(pending)
        XCTAssertNotNil(manager.lastErrorMessage)

        store.purchaseError = FakeFailure.network
        let failed = await manager.purchase()
        XCTAssertFalse(failed)
        XCTAssertTrue(manager.lastErrorMessage?.contains("Network unreachable") == true)
        XCTAssertFalse(manager.isUnlocked)
        XCTAssertFalse(manager.purchaseInFlight)
        XCTAssertTrue(store.finishedTransactionIDs.isEmpty)
    }

    func testTrialRequiresFreeNonConsumableAndVisiblePaidUnlockPrice() async {
        let invalidCatalogs: [[StoreProduct]] = [
            [paidProduct()],
            [trialProduct(price: 1), paidProduct()],
            [trialProduct(type: .other), paidProduct()],
            [trialProduct()],
            [trialProduct(), paidProduct(displayPrice: "")],
            [trialProduct(), paidProduct(displayPrice: "  \n  ")],
            [trialProduct(), paidProduct(price: 0)],
            [trialProduct(), paidProduct(type: .other)],
        ]
        for catalog in invalidCatalogs {
            let store = FakePurchaseStore()
            store.catalog = catalog
            let manager = await loadedManager(store: store, clock: TestClock(referenceDate))
            XCTAssertFalse(manager.canStartTrial, "Invalid catalog: \(catalog)")
            let succeeded = await manager.startTrial()
            XCTAssertFalse(succeeded)
            XCTAssertFalse(manager.hasStartedTrial)
            XCTAssertTrue(store.purchasedProductIDs.isEmpty)
            XCTAssertNotNil(manager.lastErrorMessage)
        }
    }

    func testProductLoadingFailureCanBeRetried() async {
        let store = FakePurchaseStore()
        store.productsError = FakeFailure.network
        let manager = EntitlementManager(store: store, now: { self.referenceDate }, automaticallyRefreshes: false)
        await manager.loadProduct()
        XCTAssertFalse(manager.isLoadingProducts)
        XCTAssertNil(manager.product)
        XCTAssertNotNil(manager.lastErrorMessage)

        store.productsError = nil
        await manager.loadProduct()
        await manager.refreshPurchased()
        XCTAssertNotNil(manager.product)
        XCTAssertNotNil(manager.trialProduct)
        XCTAssertTrue(manager.canStartTrial)
    }

    func testFailedCatalogRefreshClearsStaleCheckoutProducts() async {
        let store = FakePurchaseStore()
        let manager = await loadedManager(store: store, clock: TestClock(referenceDate))
        XCTAssertTrue(manager.canStartTrial)
        store.productsError = FakeFailure.network
        await manager.loadProduct()
        XCTAssertNil(manager.product)
        XCTAssertNil(manager.trialProduct)
        XCTAssertFalse(manager.canStartTrial)
        XCTAssertNotNil(manager.lastErrorMessage)
    }

    func testFailedEntitlementRefreshKeepsPreviouslyVerifiedPaidAccess() async {
        let store = FakePurchaseStore(entitlements: [.verified(unlockTransaction(at: referenceDate))])
        let manager = await loadedManager(store: store, clock: TestClock(referenceDate))
        store.entitlementsError = FakeFailure.network
        await manager.restore()
        XCTAssertTrue(manager.isPurchased)
        XCTAssertEqual(manager.accessState, .purchased)
        XCTAssertTrue(manager.lastErrorMessage?.contains("Network unreachable") == true)
        XCTAssertFalse(manager.restoreInFlight)
    }

    func testRestoreDistinguishesErrorCancellationAndEmptyResult() async {
        let store = FakePurchaseStore()
        let manager = await loadedManager(store: store, clock: TestClock(referenceDate))

        store.synchronizeError = FakeFailure.network
        await manager.restore()
        XCTAssertTrue(manager.lastErrorMessage?.contains("Network unreachable") == true)
        XCTAssertFalse(manager.restoreInFlight)

        store.synchronizeError = CancellationError()
        await manager.restore()
        XCTAssertNil(manager.lastErrorMessage)
        XCTAssertFalse(manager.restoreInFlight)

        store.synchronizeError = nil
        await manager.restore()
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertFalse(manager.isPurchased)
        XCTAssertFalse(manager.restoreInFlight)
    }

    func testOverlappingPurchasesAndRestoreDoNotOpenMultipleStoreOperations() async {
        let store = FakePurchaseStore()
        let manager = await loadedManager(store: store, clock: TestClock(referenceDate))
        store.suspendPurchase = true
        let first = Task { await manager.purchase() }
        await waitUntil { store.purchaseContinuation != nil }
        XCTAssertTrue(manager.purchaseInFlight)

        let duplicate = await manager.purchase()
        let overlappingTrial = await manager.startTrial()
        await manager.restore()
        XCTAssertFalse(duplicate)
        XCTAssertFalse(overlappingTrial)
        XCTAssertEqual(store.purchasedProductIDs, [EntitlementManager.unlockProductID])
        XCTAssertEqual(store.synchronizeCalls, 0)

        store.resumePurchase(.userCancelled)
        let firstResult = await first.value
        XCTAssertFalse(firstResult)
        XCTAssertFalse(manager.purchaseInFlight)
    }

    func testRefundUpdateRechecksCurrentEntitlements() async {
        let clock = TestClock(referenceDate.addingTimeInterval(90 * 86_400))
        let store = FakePurchaseStore(entitlements: [.verified(unlockTransaction(at: referenceDate))])
        let manager = await loadedManager(store: store, clock: clock)
        manager.start()
        await waitUntil { store.entitlementCalls >= 2 }
        XCTAssertTrue(manager.isPurchased)

        store.entitlements = [.verified(trialTransaction(at: referenceDate))]
        store.sendUpdate(.verified(StoreTransaction(id: 2, productID: EntitlementManager.unlockProductID,
                                                    purchaseDate: referenceDate, revocationDate: clock.now)))
        await waitUntil { manager.accessState == .expired && !manager.isLoadingEntitlements }
        XCTAssertEqual(manager.accessState, .expired)
        XCTAssertFalse(manager.isUnlocked)
    }

    func testStaleEntitlementSnapshotCannotRelockVerifiedPurchase() async {
        let store = FakePurchaseStore()
        let manager = await loadedManager(store: store, clock: TestClock(referenceDate))
        store.suspendNextEntitlementRead = true
        let staleRefresh = Task { await manager.refreshPurchased() }
        await waitUntil { store.entitlementContinuation != nil }

        store.purchaseResult = .success(.verified(unlockTransaction(at: referenceDate)))
        let checkout = Task { await manager.purchase() }
        await waitUntil { !store.purchasedProductIDs.isEmpty }
        store.resumeEntitlements([])

        let succeeded = await checkout.value
        await staleRefresh.value
        XCTAssertTrue(succeeded)
        XCTAssertTrue(manager.isPurchased)
        XCTAssertEqual(manager.accessState, .purchased)
        XCTAssertEqual(store.entitlementCalls, 3, "Discard and retry the stale snapshot")
    }

    func testPendingMessageClearsWhenVerifiedPurchaseUpdateArrives() async {
        let store = FakePurchaseStore()
        let manager = await loadedManager(store: store, clock: TestClock(referenceDate))
        manager.start()
        await waitUntil { store.entitlementCalls >= 2 }
        store.purchaseResult = .pending
        _ = await manager.purchase()
        XCTAssertNotNil(manager.lastErrorMessage)

        let transaction = unlockTransaction(at: referenceDate)
        store.entitlements = [.verified(transaction)]
        store.sendUpdate(.verified(transaction))
        await waitUntil { manager.isPurchased }
        XCTAssertNil(manager.lastErrorMessage)
        XCTAssertEqual(store.finishedTransactionIDs, [transaction.id])
    }

    private func loadedManager(store: FakePurchaseStore, clock: TestClock) async -> EntitlementManager {
        let manager = EntitlementManager(store: store, now: { clock.now }, automaticallyRefreshes: false)
        await manager.loadProduct()
        await manager.refreshPurchased()
        return manager
    }

    private func trialTransaction(at date: Date) -> StoreTransaction {
        StoreTransaction(id: 1, productID: EntitlementManager.trialProductID, purchaseDate: date)
    }

    private func unlockTransaction(at date: Date) -> StoreTransaction {
        StoreTransaction(id: 2, productID: EntitlementManager.unlockProductID, purchaseDate: date)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for a store operation", file: file, line: line)
    }
}

@MainActor
private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private enum FakeFailure: LocalizedError {
    case network
    var errorDescription: String? { "Network unreachable" }
}

private func trialProduct(price: Decimal = 0, type: StoreProductType = .nonConsumable) -> StoreProduct {
    StoreProduct(id: "app.vektor.Vektor.trial60", displayPrice: "Free", price: price, type: type)
}

private func paidProduct(displayPrice: String = "$9.99", price: Decimal = Decimal(string: "9.99")!,
                         type: StoreProductType = .nonConsumable) -> StoreProduct {
    StoreProduct(id: "app.vektor.Vektor.unlock", displayPrice: displayPrice, price: price, type: type)
}

@MainActor
private final class FakePurchaseStore: PurchaseStore {
    var catalog = [trialProduct(), paidProduct()]
    var entitlements: [StoreVerification]
    var purchaseResult: StorePurchaseResult = .userCancelled
    var productsError: Error?
    var entitlementsError: Error?
    var purchaseError: Error?
    var synchronizeError: Error?
    var productsCalls = 0
    var entitlementCalls = 0
    var synchronizeCalls = 0
    var purchasedProductIDs: [String] = []
    var finishedTransactionIDs: [UInt64] = []
    var suspendPurchase = false
    var purchaseContinuation: CheckedContinuation<StorePurchaseResult, Error>?
    var suspendNextEntitlementRead = false
    var entitlementContinuation: CheckedContinuation<[StoreVerification], Error>?
    private let updateStream: AsyncStream<StoreVerification>
    private let updateContinuation: AsyncStream<StoreVerification>.Continuation

    init(entitlements: [StoreVerification] = []) {
        self.entitlements = entitlements
        var continuation: AsyncStream<StoreVerification>.Continuation!
        updateStream = AsyncStream { continuation = $0 }
        updateContinuation = continuation
    }

    func products(for productIDs: [String]) async throws -> [StoreProduct] {
        productsCalls += 1
        if let productsError { throw productsError }
        return catalog.filter { productIDs.contains($0.id) }
    }

    func currentEntitlements() async throws -> [StoreVerification] {
        entitlementCalls += 1
        if let entitlementsError { throw entitlementsError }
        if suspendNextEntitlementRead {
            suspendNextEntitlementRead = false
            return try await withCheckedThrowingContinuation { entitlementContinuation = $0 }
        }
        return entitlements
    }

    func purchase(productID: String) async throws -> StorePurchaseResult {
        purchasedProductIDs.append(productID)
        if let purchaseError { throw purchaseError }
        let result: StorePurchaseResult
        if suspendPurchase {
            result = try await withCheckedThrowingContinuation { purchaseContinuation = $0 }
        } else {
            result = purchaseResult
        }
        if case .success(.verified(let transaction)) = result {
            entitlements.removeAll {
                if case .verified(let existing) = $0 { return existing.productID == transaction.productID }
                return false
            }
            entitlements.append(.verified(transaction))
        }
        return result
    }

    func synchronize() async throws {
        synchronizeCalls += 1
        if let synchronizeError { throw synchronizeError }
    }

    func finish(transactionID: UInt64) async { finishedTransactionIDs.append(transactionID) }
    func updates() -> AsyncStream<StoreVerification> { updateStream }
    func sendUpdate(_ update: StoreVerification) { updateContinuation.yield(update) }

    func resumePurchase(_ result: StorePurchaseResult) {
        let continuation = purchaseContinuation
        purchaseContinuation = nil
        continuation?.resume(returning: result)
    }

    func resumeEntitlements(_ entitlements: [StoreVerification]) {
        let continuation = entitlementContinuation
        entitlementContinuation = nil
        continuation?.resume(returning: entitlements)
    }
}
