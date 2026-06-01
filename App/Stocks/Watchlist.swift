import SwiftUI

/// Persistent, ordered list of tickers the user wants to keep an eye
/// on, plus the latest fetched quote for each. Distinct from the
/// (implicit) `recentTickers` list — recents track what you've looked
/// at lately; the watchlist is what you've explicitly *committed* to
/// tracking. One-click switch into deep analysis from any tile.
///
/// Quotes are best-effort: fetched on pane open (with a 5-minute
/// freshness window so the budget isn't burned on every re-open) and
/// when a ticker is starred. Failures are silent — the tile just
/// shows "—" and the user can hit the manual refresh button to retry.
@MainActor
final class WatchlistStore: ObservableObject {
    @Published private(set) var tickers: [String]
    @Published private(set) var quotes: [String: QuoteSnapshot] = [:]
    @Published private(set) var refreshing: Bool = false

    private var lastRefreshAt: Date?
    private static let storageKey = "vektor.stocks.watchlist"
    private static let freshWindow: TimeInterval = 5 * 60

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        self.tickers = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }

    func contains(_ ticker: String) -> Bool {
        tickers.contains(ticker.uppercased())
    }

    /// Add or remove a ticker. Adding auto-fetches its quote in the
    /// background so the tile populates without the user pressing
    /// refresh. Removing drops the cached quote too.
    func toggle(_ ticker: String) {
        let upper = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        guard !upper.isEmpty else { return }
        if let idx = tickers.firstIndex(of: upper) {
            tickers.remove(at: idx)
            quotes.removeValue(forKey: upper)
        } else {
            tickers.append(upper)
            Task { await self.refresh(only: upper) }
        }
        persist()
    }

    func remove(_ ticker: String) {
        let upper = ticker.uppercased()
        if let idx = tickers.firstIndex(of: upper) {
            tickers.remove(at: idx)
            quotes.removeValue(forKey: upper)
            persist()
        }
    }

    private func persist() {
        UserDefaults.standard.set(tickers.joined(separator: ","),
                                  forKey: Self.storageKey)
    }

    /// Refresh every watchlist quote in parallel. Forced — bypasses the
    /// freshness window. Wire to the manual refresh button.
    func refreshAll() async {
        refreshing = true
        defer { refreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for t in tickers {
                group.addTask { await self.refresh(only: t) }
            }
        }
        lastRefreshAt = Date()
    }

    /// Refresh only if quotes haven't been touched in `freshWindow`.
    /// Called on pane appear so a quick re-open doesn't re-hit the API.
    func refreshIfStale() async {
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < Self.freshWindow {
            return
        }
        await refreshAll()
    }

    private func refresh(only ticker: String) async {
        struct Row: Decodable {
            let price: Double?
            let change: Double?
            // Some FMP responses serve the percent precomputed; others
            // don't. We accept either and fall back to deriving it from
            // `change` + the implied previous close.
            let changesPercentage: Double?
        }
        do {
            let payload = try await FMPClient.shared.fetch(.quote, symbol: ticker)
            let rows = try JSONDecoder().decode([Row].self, from: payload.json)
            guard let row = rows.first, let price = row.price else { return }
            let change = row.change ?? 0
            let pct: Double = {
                if let p = row.changesPercentage { return p }
                let prevClose = price - change
                return prevClose > 0 ? (change / prevClose) * 100 : 0
            }()
            quotes[ticker.uppercased()] = QuoteSnapshot(
                price: price,
                change: change,
                changePercent: pct,
                fetchedAt: Date()
            )
        } catch {
            // Silent — tile renders "—" and the user can hit refresh.
        }
    }
}

/// One quote in time. Tiny struct (4 stored values) so the published
/// dictionary stays cheap to publish.
struct QuoteSnapshot: Equatable {
    let price: Double
    let change: Double
    let changePercent: Double
    let fetchedAt: Date
}

// MARK: - UI

/// Adaptive grid of watchlist tiles. Adapts to pane width via SwiftUI's
/// `.adaptive` grid item — narrow panes show two columns, wide panes
/// five. Each tile is one-click → switch the analysis to that ticker.
struct WatchlistGrid: View {
    let tickers: [String]
    let quotes: [String: QuoteSnapshot]
    let currentTicker: String
    let onSelect: (String) -> Void
    let onUnstar: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(tickers, id: \.self) { ticker in
                WatchlistChip(
                    ticker: ticker,
                    quote: quotes[ticker],
                    isCurrent: ticker == currentTicker,
                    onTap: { onSelect(ticker) },
                    onUnstar: { onUnstar(ticker) }
                )
            }
        }
    }
}

/// Single tile: ticker on the left, price + change% on the right. Current
/// ticker gets an accent border + a subtle tint so the user can see at
/// a glance "this is the one I'm analysing right now." Right-click
/// removes from the watchlist.
private struct WatchlistChip: View {
    let ticker: String
    let quote: QuoteSnapshot?
    let isCurrent: Bool
    let onTap: () -> Void
    let onUnstar: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(ticker)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(VektorTheme.text)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let q = quote {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(formatPrice(q.price))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(VektorTheme.text)
                        Text(formatPercent(q.changePercent))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(q.changePercent >= 0
                                             ? VektorTheme.statusGood
                                             : VektorTheme.statusBad)
                    }
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(VektorTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isCurrent
                        ? VektorTheme.accent.opacity(0.18)
                        : VektorTheme.codeSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isCurrent ? VektorTheme.accent : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from watchlist", role: .destructive, action: onUnstar)
        }
        .help(quote.map {
            "\(ticker) · \(formatPrice($0.price)) · \(formatPercent($0.changePercent))"
        } ?? "\(ticker) · click refresh for live price")
    }

    private func formatPrice(_ p: Double) -> String {
        // No currency symbol — FMP returns the listing currency without
        // a symbol, and most watchlist tickers on the free tier are USD.
        // Plain decimal keeps tiles compact and currency-neutral.
        String(format: "%.2f", p)
    }

    private func formatPercent(_ p: Double) -> String {
        String(format: "%+.1f%%", p)
    }
}
