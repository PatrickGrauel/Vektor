import SwiftUI
import AppKit

/// Self-contained "manage Stocks" surface. Same content lives in Settings →
/// Stocks (for the user who navigates to Settings first) and in the pane's
/// footer popover (for the user who's already in Stocks and doesn't want
/// to leave). The API-key field never *reads* the Keychain — it shows a
/// "(stored)" placeholder when a key is present and an empty field when
/// not — so opening this view does not trigger a Keychain prompt.
/// Typing a new value into the field writes it through to the Keychain
/// and updates the presence boolean. The plan/cap bindings flow into
/// UserDefaults via `@AppStorage`. Both surfaces stay in sync.
///
/// The view answers four questions in one card:
///   1. What key am I using?                                  (SecureField)
///   2. Which plan am I on, and what's my daily cap?          (Plan dropdown)
///   3. Is it working right now?                              (status dot + label)
///   4. How much have I used today, and what does it cost?    (usage + call-cost note)
struct StocksManageView: View {
    /// Whether the Keychain currently has an FMP key. Read from a
    /// UserDefaults mirror so this view can render without triggering
    /// a Keychain prompt at appearance time.
    @AppStorage("vektor.stocks.fmpApiKey.present") private var hasFMPKey: Bool = false
    /// Buffer for a new key the user is currently typing. The actual
    /// stored key is never displayed back into this field — SecureFields
    /// don't help anyone by echoing a secret, even masked.
    @State private var newKey: String = ""
    @AppStorage(FMPPlan.storageKey)           private var planRaw: String = FMPPlan.free.rawValue
    @AppStorage(FMPPlan.customCapKey)         private var customCap: Int = 240
    @StateObject private var monitor = StocksConnectionMonitor.shared
    @State private var budget: FMPClient.BudgetSnapshot?

    /// When embedded in a popover we want a fixed width; when used as a
    /// Settings section we let the form decide. Caller picks.
    var fixedWidth: CGFloat? = nil
    var titleVisible: Bool = true

    private var plan: FMPPlan {
        FMPPlan(rawValue: planRaw) ?? .free
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if titleVisible {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VektorTheme.accent)
                    Text("Stocks data source")
                        .font(.headline)
                }
            }

            // Key
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("FMP API key").font(.caption).foregroundStyle(.secondary)
                    if hasFMPKey {
                        Text("· stored")
                            .font(.caption2)
                            .foregroundStyle(VektorTheme.statusGood)
                    }
                    Spacer()
                    if hasFMPKey {
                        Button("Clear") {
                            KeychainStorage.delete("vektor.stocks.fmpApiKey")
                            newKey = ""
                            monitor.reflectKeyPresence(present: false)
                            Task { await FMPClient.shared.setAPIKey(nil) }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                    }
                }
                SecureField(
                    "",
                    text: $newKey,
                    prompt: Text(hasFMPKey ? "Paste a new key to replace the stored one" : "Paste your free FMP key")
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitNewKeyIfNeeded() }
                .onChange(of: newKey) { _, new in
                    // Trim aggressively — pasted keys often carry stray
                    // whitespace. Commit immediately so the user doesn't
                    // have to press return after pasting.
                    let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != new { newKey = trimmed; return }
                    if !trimmed.isEmpty { commitNewKeyIfNeeded() }
                }
                Text("FMP's Free plan covers ~250 calls/day — enough for casual use. Upgrade to a paid plan only if you hit the cap. Vektor reads the cap from the Plan picker below to budget calls locally.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Stored in the macOS Keychain. macOS may ask permission the first time Vektor *uses* the key (e.g. analysing a ticker) — that's the system protecting the secret. Opening this view never touches the Keychain.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Plan
            VStack(alignment: .leading, spacing: 4) {
                Text("Plan").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { plan },
                    set: { planRaw = $0.rawValue
                        Task { await refreshBudget() }
                    }
                )) {
                    ForEach(FMPPlan.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if plan == .custom {
                    HStack(spacing: 6) {
                        Text("Cap").font(.caption).foregroundStyle(.secondary)
                        TextField("", value: $customCap, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onChange(of: customCap) { _, _ in
                                Task { await refreshBudget() }
                            }
                        Text("calls/day").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // Status
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.dotColour)
                    .frame(width: 8, height: 8)
                Text(monitor.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Usage
            if let b = budget {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today's usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(b.callsToday) / \(b.callsLimit) calls · \(byteString(b.bytesToday)) / \(byteString(b.bytesLimit))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Honest accounting — how the call cost actually breaks down.
            // Reads like a fact sheet, not marketing.
            VStack(alignment: .leading, spacing: 3) {
                infoLine("Each full analysis costs **5 calls** (income statement, balance sheet, cash flow, key metrics, profile).")
                infoLine("A coverage-gap lookup (ticker not in your plan) costs **1 call** after the pre-flight check.")
                infoLine("Cached tickers are **free for 7 days** — re-running KO tomorrow is zero calls.")
                infoLine("Vektor enforces this cap **locally**. Even if your FMP plan allows more, Vektor won't let any single day cost more than this number — a hard guardrail against runaway usage, regardless of plan.")
            }

            HStack(spacing: 12) {
                Link(destination: URL(string: "https://site.financialmodelingprep.com/developer/docs")!) {
                    Label("Get a free key", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                Link(destination: URL(string: "https://site.financialmodelingprep.com/developer/docs/pricing")!) {
                    Label("See plans", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .frame(width: fixedWidth)
        .task { await refreshBudget() }
        .onChange(of: monitor.status) { _, _ in
            Task { await refreshBudget() }
        }
    }

    private func commitNewKeyIfNeeded() {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStorage.set(trimmed, for: "vektor.stocks.fmpApiKey")
        newKey = ""
        monitor.reflectKeyPresence(present: true)
        Task { await FMPClient.shared.refreshAPIKeyFromKeychain() }
    }

    private func refreshBudget() async {
        let snap = await FMPClient.shared.budgetSnapshot()
        await MainActor.run { budget = snap }
    }

    private func byteString(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func infoLine(_ markdown: String) -> some View {
        Text(.init(markdown))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
