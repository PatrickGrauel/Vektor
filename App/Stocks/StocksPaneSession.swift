import SwiftUI

/// State that needs to survive switching away from the Stocks pane and
/// back. Previously this state lived as `@State` inside `StocksPane`,
/// which meant SwiftUI tore it down every time the user navigated to
/// Calculator or anywhere else — they'd return to an empty "type a
/// ticker" screen and have to re-analyse, burning API budget for no
/// reason. Owning it at ContentView level (as a `@StateObject`) keeps
/// the loaded scorecard alive for the whole app session.
///
/// Cross-app-restart persistence is deliberately *not* here — that
/// would need `DCAScorecard` (and its nested types) to be Codable, a
/// larger refactor. The last-analysed ticker IS persisted via
/// `UserDefaults` so the input field repopulates on launch, but the
/// user has to press Analyze once after launch to refresh the figures.
@MainActor
final class StocksPaneSession: ObservableObject {
    @Published var ticker: String = ""
    @Published var scorecard: DCAScorecard?
    @Published var analysisError: StocksAnalysisError?
    @Published var expandedAxes: Set<Axis> = []
    @Published var loading: Bool = false
    /// In-flight analysis. Lives on the session so an analysis kicked
    /// off in the Stocks pane survives a navigation away — the user
    /// can switch to Calculator while NVDA's bundle is fetching, come
    /// back, and find the scorecard already there.
    var task: Task<Void, Never>?

    let watchlist = WatchlistStore()

    private static let lastTickerKey = "vektor.stocks.lastTicker"

    init() {
        let last = UserDefaults.standard.string(forKey: Self.lastTickerKey) ?? ""
        if !last.isEmpty { self.ticker = last }
    }

    /// Persist the symbol most recently analysed so the input field
    /// repopulates on next launch. Called by the pane after a
    /// successful analyse() completes.
    func rememberLastAnalysed(_ ticker: String) {
        UserDefaults.standard.set(ticker, forKey: Self.lastTickerKey)
    }
}

/// Top-level (formerly `StocksPane.AnalysisError`). Hoisted so the
/// session can hold it without exposing a nested type across files.
enum StocksAnalysisError: Equatable {
    case coverageGap(symbol: String)
    case invalidKey
    case generic(String)
}
