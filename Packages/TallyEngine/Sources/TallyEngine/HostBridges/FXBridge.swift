import Foundation
import JavaScriptCore

/// Pushes FX rate snapshots into the JS context so currency-as-unit math
/// works (`100 EUR to USD`).
public enum FXBridge {

    public static func apply(_ snapshot: FXService.Snapshot, to context: JSContext) {
        guard let tally = context.objectForKeyedSubscript("tally") else { return }
        let setCurrency = tally.objectForKeyedSubscript("setCurrency")
        for (code, rate) in snapshot.ratesPerUSD where rate.isFinite && rate > 0 {
            _ = setCurrency?.call(withArguments: [code, rate])
        }
    }
}

public enum CryptoBridge {
    public static func apply(_ snapshot: CryptoService.Snapshot, to context: JSContext) {
        guard let tally = context.objectForKeyedSubscript("tally") else { return }
        let setCurrency = tally.objectForKeyedSubscript("setCurrency")
        // CoinGecko gives USD price per coin. We want "rate per USD" semantics
        // matching FXBridge: 1 USD = ratePerUSD × UNIT. So ratePerUSD = 1/price.
        for (code, priceUSD) in snapshot.pricesUSD where priceUSD.isFinite && priceUSD > 0 {
            _ = setCurrency?.call(withArguments: [code, 1.0 / priceUSD])
        }
    }
}
