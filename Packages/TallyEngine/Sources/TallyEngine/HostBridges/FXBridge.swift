import Foundation
import JavaScriptCore
import os

/// Pushes FX rate snapshots into the JS context so currency-as-unit math
/// works (`100 EUR to USD`).
public enum FXBridge {
    private static let logger = Logger(subsystem: "app.tally.Tally", category: "fx-bridge")

    /// Apply a snapshot to the JS context. Returns the number of currency
    /// units that were successfully registered — caller can use this to
    /// detect a silently-broken bridge (`applied == 0` for a non-empty
    /// snapshot means `tally.setCurrency` isn't reachable).
    @discardableResult
    public static func apply(_ snapshot: FXService.Snapshot, to context: JSContext) -> Int {
        // `objectForKeyedSubscript` always returns a non-nil JSValue
        // (wrapping `undefined` if the key doesn't exist) — we treat that
        // case explicitly so a broken bundle is loud.
        guard let tally = context.objectForKeyedSubscript("tally"),
              tally.isUndefined == false, tally.isNull == false
        else {
            logger.error("apply: no `tally` global in JS context — bundle didn't load?")
            return 0
        }
        let setCurrency = tally.objectForKeyedSubscript("setCurrency")
        guard let setCurrency, setCurrency.isUndefined == false else {
            logger.error("apply: `tally.setCurrency` missing")
            return 0
        }
        var applied = 0
        for (code, rate) in snapshot.ratesPerUSD where rate.isFinite && rate > 0 {
            _ = setCurrency.call(withArguments: [code, rate])
            applied += 1
        }
        return applied
    }
}

public enum CryptoBridge {
    private static let logger = Logger(subsystem: "app.tally.Tally", category: "crypto-bridge")

    @discardableResult
    public static func apply(_ snapshot: CryptoService.Snapshot, to context: JSContext) -> Int {
        guard let tally = context.objectForKeyedSubscript("tally") else {
            logger.error("apply: no `tally` global in JS context")
            return 0
        }
        guard let setCurrency = tally.objectForKeyedSubscript("setCurrency"),
              setCurrency.isUndefined == false
        else {
            logger.error("apply: `tally.setCurrency` missing")
            return 0
        }
        var applied = 0
        // CoinGecko gives USD price per coin. We want "rate per USD" semantics
        // matching FXBridge: 1 USD = ratePerUSD × UNIT. So ratePerUSD = 1/price.
        for (code, priceUSD) in snapshot.pricesUSD where priceUSD.isFinite && priceUSD > 0 {
            _ = setCurrency.call(withArguments: [code, 1.0 / priceUSD])
            applied += 1
        }
        return applied
    }
}
