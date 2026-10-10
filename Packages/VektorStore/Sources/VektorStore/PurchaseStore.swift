import Foundation

public enum StoreProductType: Equatable, Sendable {
    case nonConsumable
    case other
}

/// Catalog information displayed before Apple's purchase sheet opens.
public struct StoreProduct: Equatable, Sendable {
    public let id: String
    public let displayPrice: String
    public let price: Decimal
    public let type: StoreProductType

    public init(id: String, displayPrice: String, price: Decimal,
                type: StoreProductType = .nonConsumable) {
        self.id = id
        self.displayPrice = displayPrice
        self.price = price
        self.type = type
    }
}

public struct StoreTransaction: Equatable, Sendable {
    public let id: UInt64
    public let productID: String
    public let purchaseDate: Date
    public let originalPurchaseDate: Date
    public let revocationDate: Date?

    public init(id: UInt64, productID: String, purchaseDate: Date,
                revocationDate: Date? = nil, originalPurchaseDate: Date? = nil) {
        self.id = id
        self.productID = productID
        self.purchaseDate = purchaseDate
        self.originalPurchaseDate = originalPurchaseDate ?? purchaseDate
        self.revocationDate = revocationDate
    }
}

public enum StoreVerification: Equatable, Sendable {
    case verified(StoreTransaction)
    case unverified(productID: String?, message: String)
}

public enum StorePurchaseResult: Equatable, Sendable {
    case success(StoreVerification)
    case userCancelled
    case pending
}

public enum PurchaseStoreError: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case productUnavailable

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The purchase was cancelled."
        case .productUnavailable: return "This purchase is unavailable. Please try again."
        }
    }
}

/// The StoreKit boundary. Tests can supply verified transactions and control
/// asynchronous requests without touching an Apple Account or a real clock.
@MainActor
public protocol PurchaseStore: AnyObject {
    func products(for productIDs: [String]) async throws -> [StoreProduct]
    func currentEntitlements() async throws -> [StoreVerification]
    func purchase(productID: String) async throws -> StorePurchaseResult
    func synchronize() async throws
    func finish(transactionID: UInt64) async
    func updates() -> AsyncStream<StoreVerification>
}
