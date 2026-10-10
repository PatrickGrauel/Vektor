import AppKit
import Foundation
import StoreKit

/// Uses StoreKit's verified transaction history and native Mac purchase sheet.
@MainActor
public final class ApplePurchaseStore: PurchaseStore {
    private var catalog: [String: Product] = [:]
    private var transactions: [UInt64: Transaction] = [:]

    public init() {}

    public func products(for productIDs: [String]) async throws -> [StoreProduct] {
        let products = try await Product.products(for: productIDs)
        for productID in productIDs { catalog.removeValue(forKey: productID) }
        for product in products { catalog[product.id] = product }
        return products.map {
            StoreProduct(id: $0.id, displayPrice: $0.displayPrice, price: $0.price,
                         type: $0.type == .nonConsumable ? .nonConsumable : .other)
        }
    }

    public func currentEntitlements() async throws -> [StoreVerification] {
        var results: [StoreVerification] = []
        for await result in Transaction.currentEntitlements {
            results.append(convert(result))
        }
        return results
    }

    public func purchase(productID: String) async throws -> StorePurchaseResult {
        guard let product = catalog[productID] else { throw PurchaseStoreError.productUnavailable }
        do {
            let result: Product.PurchaseResult
            if #available(macOS 15.2, *), let window = NSApplication.shared.keyWindow {
                result = try await product.purchase(confirmIn: window)
            } else {
                result = try await product.purchase()
            }
            switch result {
            case .success(let verification): return .success(convert(verification))
            case .userCancelled: return .userCancelled
            case .pending: return .pending
            @unknown default: throw PurchaseStoreError.productUnavailable
            }
        } catch {
            if isCancelled(error) { throw PurchaseStoreError.cancelled }
            throw error
        }
    }

    public func synchronize() async throws {
        do {
            try await AppStore.sync()
        } catch {
            if isCancelled(error) { throw PurchaseStoreError.cancelled }
            throw error
        }
    }

    public func finish(transactionID: UInt64) async {
        guard let transaction = transactions[transactionID] else { return }
        await transaction.finish()
        transactions.removeValue(forKey: transactionID)
    }

    public func updates() -> AsyncStream<StoreVerification> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                for await result in Transaction.updates {
                    guard !Task.isCancelled, let self else { break }
                    continuation.yield(self.convert(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func convert(_ result: VerificationResult<Transaction>) -> StoreVerification {
        switch result {
        case .verified(let transaction):
            transactions[transaction.id] = transaction
            return .verified(StoreTransaction(id: transaction.id,
                                              productID: transaction.productID,
                                              purchaseDate: transaction.purchaseDate,
                                              revocationDate: transaction.revocationDate,
                                              originalPurchaseDate: transaction.originalPurchaseDate))
        case .unverified(let transaction, let error):
            return .unverified(productID: transaction.productID, message: error.localizedDescription)
        }
    }

    private func isCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let storeError = error as? StoreKitError, case .userCancelled = storeError { return true }
        let nsError = error as NSError
        return nsError.domain == SKErrorDomain && nsError.code == SKError.paymentCancelled.rawValue
    }
}
