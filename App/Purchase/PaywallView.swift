import SwiftUI
import AppKit

/// Blocking unlock screen shown over the panel once the trial has lapsed and
/// nothing is purchased. Also presented as a sheet from the trial banner so
/// users can buy early.
struct PaywallView: View {
    @EnvironmentObject private var ent: EntitlementManager
    /// Non-nil when shown as a dismissible sheet (early unlock); nil when shown
    /// as the blocking, full-bleed overlay after the trial ends.
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            if let onClose {
                HStack {
                    Spacer()
                    Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Close")
                }
            }

            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)

            Text("Unlock Vektor").font(.title.bold())
            Text(headline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                feature("Smart calculator — units, currency & time-zones")
                feature("Finance, aviation, stocks & live METAR map")
                feature("One-time purchase — no subscription")
            }
            .padding(.vertical, 4)

            VStack(spacing: 10) {
                Button {
                    Task { if await ent.purchase(), let onClose { onClose() } }
                } label: {
                    HStack(spacing: 8) {
                        if ent.purchaseInFlight { ProgressView().controlSize(.small) }
                        Text(buyTitle)
                    }
                    .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(ent.purchaseInFlight || ent.product == nil)

                Button("Restore Purchase") { Task { await ent.restore() } }
                    .buttonStyle(.link)
                    .disabled(ent.purchaseInFlight)
            }

            if let err = ent.lastErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var headline: String {
        if ent.isTrialActive {
            return "You're on the free trial — \(ent.trialDaysRemaining) day\(ent.trialDaysRemaining == 1 ? "" : "s") left. Unlock once to keep everything, forever."
        }
        return "Your 7-day free trial has ended. Unlock Vektor with a one-time purchase to keep using it."
    }

    private var buyTitle: String {
        if let p = ent.product { return "Unlock — \(p.displayPrice)" }
        return "Unlock"
    }

    private func feature(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.callout)
    }
}
