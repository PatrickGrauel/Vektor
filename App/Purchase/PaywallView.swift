import SwiftUI
import AppKit

/// Starts the App Store trial or offers a lifetime unlock after it ends.
struct PaywallView: View {
    @EnvironmentObject private var ent: EntitlementManager
    var onClose: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let onClose {
                    HStack {
                        Spacer()
                        Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Close")
                            .accessibilityLabel("Close purchase options")
                    }
                }

                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                Text(ent.hasStartedTrial ? "Unlock Vektor" : "Try Vektor for 60 days")
                    .font(.title.bold())
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    feature("Calculations, units, currencies and time zones")
                    feature("Finance and aviation tools for study and reference")
                    feature("One-time unlock. No subscription or automatic charge.")
                }
                .padding(.vertical, 4)

                VStack(spacing: 10) {
                    if !ent.hasStartedTrial {
                        Button {
                            Task { if await ent.startTrial(), let onClose { onClose() } }
                        } label: {
                            HStack(spacing: 8) {
                                if ent.purchaseInFlight { ProgressView().controlSize(.small) }
                                Text("Start 60-day free trial")
                            }
                            .frame(maxWidth: 300)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!ent.canStartTrial)
                    }

                    Button {
                        Task { if await ent.purchase(), let onClose { onClose() } }
                    } label: {
                        HStack(spacing: 8) {
                            if ent.purchaseInFlight && ent.hasStartedTrial {
                                ProgressView().controlSize(.small)
                            }
                            Text(buyTitle)
                        }
                        .frame(maxWidth: 300)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(ent.isBusy || ent.product == nil)

                    Button(ent.restoreInFlight ? "Restoring purchases…" : "Restore Purchases") {
                        Task { await ent.restore() }
                    }
                    .buttonStyle(.link)
                    .disabled(ent.isBusy)

                    if ent.isLoadingProducts {
                        ProgressView("Loading App Store prices…")
                            .controlSize(.small)
                    } else if ent.product == nil || (!ent.hasStartedTrial && ent.trialProduct == nil) {
                        Button("Retry App Store connection") { Task { await ent.loadProduct() } }
                            .disabled(ent.isBusy)
                    }
                }

                if let error = ent.lastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }

                HStack(spacing: 16) {
                    Link("Privacy policy", destination: ReleaseLinks.privacy)
                    Link("Support", destination: ReleaseLinks.support)
                    Link("Terms", destination: ReleaseLinks.terms)
                }
                .font(.caption)
            }
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .background(.ultraThinMaterial)
        .onChange(of: ent.isPurchased) { _, purchased in
            if purchased { onClose?() }
        }
    }

    private var headline: String {
        if ent.isPurchased { return "Vektor is unlocked for your Apple Account." }
        if ent.isTrialActive {
            return "Your free trial has \(ent.trialDaysRemaining) day\(ent.trialDaysRemaining == 1 ? "" : "s") left. Unlock once to keep using every tool."
        }
        if ent.hasStartedTrial {
            return "Your 60-day trial has ended. A one-time lifetime unlock restores access to all calculation tools. Your saved sheets stay on your Mac."
        }
        let cost = ent.product.map { " A lifetime unlock costs \($0.displayPrice), paid once." } ?? ""
        return "Use every Vektor tool free for 60 days. After the trial, the calculation tools require a lifetime unlock.\(cost) Apple handles both the free trial and the purchase."
    }

    private var buyTitle: String {
        ent.product.map { "Unlock for life — \($0.displayPrice)" } ?? "Unlock for life"
    }

    private func feature(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout)
    }
}
