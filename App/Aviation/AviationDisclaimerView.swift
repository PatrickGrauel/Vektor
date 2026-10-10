import SwiftUI

/// One-time aviation disclaimer shown on the first visit to the Aviation
/// pane. Acceptance is persisted in `vektor.aviation.disclaimerAccepted`.
/// This is in addition to — not in place of — the README safety notice
/// and the full DISCLAIMER.md in the repository.
struct AviationDisclaimerView: View {
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                Text("**Vektor is not certified, approved, or audited for flight planning, navigation, or operation of an aircraft.** Its aviation features are provided for situational awareness and study only.")
                    .fixedSize(horizontal: false, vertical: true)

                bullet("**Weather data is third-party** (aviationweather.gov, datis.clowd.io) and may be delayed, cached, incomplete, or unavailable.")
                bullet("**Calculations are generic estimates.** E6B, density altitude, and fuel figures are computed from standard atmospheric and aerodynamic models. They do not account for your aircraft's actual performance, equipment, or condition.")
                bullet("**Always cross-check** against official weather products, NOTAMs, your aircraft's POH/AFM, and certified flight planning systems before and during every flight.")
                bullet("**The Pilot in Command remains solely responsible** for the safe conduct of the flight per applicable regulations (14 CFR § 91 in the U.S., EASA Air OPS / SERA in the EU, or your operating state's equivalent).")
                bullet("Provided **AS IS, WITHOUT WARRANTY OF ANY KIND**. No liability accepted for any direct, indirect, incidental, special, or consequential damages — including loss of life, personal injury, property damage, or loss of aircraft — arising from use of this software.")

                Divider().padding(.vertical, 8)

                Text("By tapping the button below you confirm you have read and accept the full disclaimer in DISCLAIMER.md, and you understand that Vektor is not to be relied upon for any flight-critical decision.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onAccept()
                } label: {
                    Text("I understand — continue to aviation tools")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 12)

                Text("If you do not accept these terms, leave this pane and use Vektor's non-aviation features only.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(VektorTheme.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Aviation features — read before using")
                .font(.title2.weight(.semibold))
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("•")
                .font(.body.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 8, alignment: .leading)
            Text(.init(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
