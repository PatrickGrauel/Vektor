# Vektor

A native macOS calculator built for pilots. A natural-language scratchpad on one side, first-class aviation tooling on the other — METAR/TAF/ATIS decoding with freshness indicators, E6B flight computer. Plus optional Finance and Buffett-style Stocks analysis modules for when you're not in the cockpit.

## Features

**Calculator (natural language)**
- Math: `2 + 2`, `8 * (3.5 + 1)`, `prev / 2`, `sum`
- Units: `120 kt in km/h`, `29.92 inHg in hPa`, `1 meter in cm`
- Currency & crypto: `100 EUR in USD`, `1 BTC in USD` (live rates)
- Dates: `days between 2024-01-15 and today`, `2026-12-25 - 30 days`, `age 1990-03-15`
- Timezones: `Berlin time`, `1430 Zulu in HKT`, `now in Tokyo + 2h`
- Variables: `rent = 1450 EUR`, then `rent * 12`. Names are case-insensitive — `Total_price` and `total_price` are the same variable.

**Aviation**
- **METAR / TAF / ATIS** — type `METAR EDDM`, `TAF KSFO`, or `ATIS KJFK` and get the live report inline with a freshness indicator (fresh / stale / outdated based on each report's actual issuance cadence). The METAR line auto-appends a wind-based runway recommendation: `expect RWY 36R · Hw 11 (G21) · Xc 2 (G4)`.
- **`altitude EDDM`** — field elevation + pressure altitude + density altitude, derived from the cached METAR's QNH and OAT. Multi-station works: `altitude EDDM EDMA KJFK`.
- **`briefing EDMA`** — METAR + TAF + every runway (wind-favoured marked `★`) + altitudes, stacked. One command for the full pre-flight scan; annotation surfaces the worst freshness across the underlying reports.
- **`RWY EDDM`** — every runway with length, surface, and true heading. **`sun EDDM`** — sunrise, sunset, civil-twilight end for today.
- **METAR Map** — pan a world map of airports colour-coded by flight category (VFR / MVFR / IFR / LIFR). Click any pin for the decoded METAR. Tier-aware density (large airports only at world span, +medium at country, +small at regional) keeps the surface responsive at every zoom.
- **E6B** — wind triangle, density altitude, runway crosswind/headwind component, top-of-descent, fuel.

**Stocks** *(off by default — enable in Vektor's pane menu → Manage panes…)*
- **DCA scorecard** — type a US-listed ticker and get a Warren Buffett-style "Durable Competitive Advantage" 6-axis scorecard (Pricing Power, Cost Discipline, Earnings Quality, Capital Efficiency, Balance Sheet Safety, Capital Allocation), each scored 0–10 against the rubric from *Warren Buffett and the Interpretation of Financial Statements* (Mary Buffett & David Clark).
- **Radar + sparklines + trend chips** — six-axis radar chart with the per-axis score next to each label, plus an inline 5-year sparkline on every row with a direction chip (↑ improving / → stable / ↓ deteriorating).
- **Drill-down with threshold bands** — click any axis to expand into a detail view showing the underlying metric's 5-year trend with Buffett's score cutoffs drawn as tinted regions. Composite axes (Cost Discipline, Balance Sheet, Capital Allocation) plot every contributing input on the same chart — Cost Discipline shows SG&A *and* R&D *and* Depreciation, so you can see which input drives the score.
- **Cached + rate-aware** — five-year statements cached on disk for 7 days; daily call budget enforced locally with plan-aware hard caps (Free / Starter / Pro / Premium / Custom). Pre-flight probe limits coverage-gap misses to one API call each. Friendly "not in your data plan" empty-state for international or paywalled tickers instead of raw HTTP errors.

Powered by [Financial Modeling Prep](https://site.financialmodelingprep.com/developer/docs) — get a free key, paste it into the in-pane setup card.

**Productivity**
- Finance scenarios — loan amortization, real estate yield, tip calculator.
- Document-based — multiple scratchpads, persisted across launches.

## ⚠️ Safety notice — aviation features

**Vektor is NOT certified, approved, audited, or operationally validated for flight planning, navigation, or operation of an aircraft.** It is a hobbyist productivity tool. Its aviation features — METAR / TAF / ATIS retrieval, E6B calculations, weight & balance, density altitude, fuel — are provided for **situational awareness and study only**.

- **Weather data is third-party.** METAR / TAF / ATIS come from external APIs (aviationweather.gov, datis.clowd.io, etc.) and may be delayed, incomplete, cached, or unavailable.
- **Calculations are generic estimates.** E6B, density altitude, and fuel figures are computed from standard atmospheric and aerodynamic models. They do **not** account for your specific aircraft's actual performance, equipment, or condition.
- **Always cross-check against official sources** — official weather products, NOTAMs, your aircraft's POH/AFM, and certified flight planning systems — before and during every flight.
- **The Pilot in Command remains solely responsible** for the safe conduct of the flight per applicable regulations (14 CFR § 91 in the U.S., EASA Air OPS / Part-NCO / SERA in the EU, or your operating state's equivalent). Using Vektor does not relieve the PIC of any obligation.

See [**DISCLAIMER.md**](DISCLAIMER.md) for the full safety and liability disclaimer. If you are not willing to accept those terms, do not install or use Vektor for any aviation-related purpose.

## ⚠️ Not financial advice — Stocks pane

**Vektor is NOT a financial advisor, broker, or registered investment professional.** The Stocks pane computes a quantitative score against one specific framework (Mary Buffett & David Clark's "Durable Competitive Advantage" rubric) from financial statements pulled from a third-party API.

- **It is not investment advice.** A high or low score is not a buy or sell recommendation. The framework is opinionated, applies primarily to mature US large-caps, and produces nonsensical results for financial-sector companies, recent IPOs, REITs, and unusual capital structures.
- **The data is third-party.** Financial Modeling Prep returns the statements; they may be delayed, incomplete, misclassified, or restated by the issuer.
- **The free tier covers a curated subset.** Many US large-caps (BRK.B, MCO, PG, HD, MA, etc.), most international listings, and delisted companies require a paid FMP plan.
- **The 5-year window understates the framework.** The book recommends 10 years; the FMP free tier returns 5. Vektor flags this in the rationale text.
- **Do your own due diligence.** Cross-check with primary sources (SEC filings, the company's annual report, earnings calls) and consult a licensed financial advisor before making any investment decision. The Pilot in Command of your portfolio is you.

## Mac App Store release

The release offers a **60-day free trial** started through Apple's zero-cost purchase sheet, followed by a **one-time lifetime unlock**. It does not renew or charge automatically. Trial dates and purchase restoration come from verified Apple transactions. The intended US unlock price is **$25.00**; the app displays the actual localized App Store price.

Both non-consumable products still need to be configured and tested in App Store Connect. The repository does not prove that the app or purchases have been submitted or approved. See [release-readiness.md](docs/app-store/release-readiness.md) for the remaining account, signing, privacy and capture work.

For development, run the **Vektor StoreKit** scheme in Xcode to exercise the trial and unlock using `Vektor.storekit` without real charges. The **Vektor** scheme uses Apple's configured environment. A standalone ad-hoc build does not automatically use the local fixture. Do not distribute the development DMG as an App Store release.

## Install a development Mac app

Vektor is distributed as source. The steps below produce a regular `Vektor.app` in `/Applications`, launchable from Spotlight, Launchpad, or the Dock.

**Requirements**
- macOS 14.0 (Sonoma) or later
- Xcode 15+ (from the Mac App Store)
- [Homebrew](https://brew.sh)

```sh
# One-time prerequisites
brew install xcodegen node

# Clone and build
git clone https://github.com/PatrickGrauel/Vektor.git
cd Vektor
xcodegen generate
(cd JS && npm install && npm run build)

# Release build, ad-hoc signed
xcodebuild -project Vektor.xcodeproj -scheme Vektor -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" build

# Install to /Applications and strip the Gatekeeper quarantine flag
rm -rf /Applications/Vektor.app
cp -R build/Build/Products/Release/Vektor.app /Applications/
xattr -dr com.apple.quarantine /Applications/Vektor.app

# Launch
open /Applications/Vektor.app
```

After this, Vektor behaves like any other Mac app — find it in Spotlight (`⌘ Space → "Vektor"`), Launchpad, or the Dock.

The `xattr` line is required because the binary is only ad-hoc signed. Without it, Gatekeeper would block first launch with *"Vektor cannot be opened because the developer cannot be verified."*

To update later: `cd` into the repo, `git pull`, then rerun the build, `cp`, and `xattr` lines.

## Build a DMG to share

`scripts/build-dmg.sh` produces a `Vektor-X.Y.Z.dmg` in `dist/` (or wherever you point `--output`). Uses only `hdiutil` so no extra Homebrew packages are needed.

```sh
./scripts/build-dmg.sh
# → dist/Vektor-1.0.0.dmg

./scripts/build-dmg.sh --output ~/Desktop
```

The DMG contains `Vektor.app` plus a symlink to `/Applications`, so a recipient drags Vektor onto Applications and is done. Because the build is ad-hoc signed, first launch needs a right-click → Open (or `xattr -dr com.apple.quarantine /Applications/Vektor.app` for fully unattended install).

For public distribution outside the Mac App Store you'll want to additionally:
- Sign with a Developer ID Application certificate (`CODE_SIGN_IDENTITY="Developer ID Application: …"`)
- Notarize the DMG via `xcrun notarytool submit … --wait` and `xcrun stapler staple`

The comments at the top of `scripts/build-dmg.sh` link to Apple's notarization docs.

## Develop

```sh
# Re-generate the Xcode project whenever project.yml changes
xcodegen generate

# Open in Xcode and run normally
open Vektor.xcodeproj

# Or build via xcodebuild
xcodebuild -scheme Vektor -configuration Debug build

# Tests
swift test --package-path Packages/VektorEngine
swift test --package-path Packages/VektorAviation
swift test --package-path Packages/VektorStore
```

The math.js JS bundle at `Packages/VektorEngine/Sources/VektorEngine/Resources/mathjs.bundle.js` is regenerated by `npm run build` in `JS/`. This only needs to rerun when `JS/entry.js` or the math.js dependency changes.

## Architecture

- `App/` — SwiftUI macOS shell. `Calculator/`, `Aviation/`, `Finance/`, `Stocks/`, `Timezone/`, `Map/` (METAR map), `Settings/`, plus the menu bar controller.
- `App/Stocks/` — DCA scoring engine, FMP API client (on-disk cache + UTC-aligned daily call budget + plan-aware hard cap), drill-down chart canvas with Buffett-rubric threshold bands, and the radar/sparkline/manage-popover UI.
- `Packages/VektorEngine` — `JSContext` + math.js bundle + a Swift preprocessor for natural-language sugar (`5% off $40`, `$20 in eur`, `today + 2 weeks`, `sum`, `prev`) + host bridges for timezone / FX / crypto / aviation / METAR cache.
- `Packages/VektorAviation` — pure-Swift E6B math, atmosphere model, METAR/TAF parser.
- `Packages/VektorStore` — verified StoreKit trial and lifetime-unlock entitlements, purchase and restore handling.
- `JS/` — npm workspace; esbuild bundles math.js into the resources directory above.

## Acknowledgements

The natural-language calculator style is inspired by [Numi](https://numi.app). Vektor is a from-scratch implementation built on **math.js** (Apache 2.0) embedded in `JSContext`, with an original preprocessor and aviation toolkit.

The Stocks pane's scoring rubric comes from **Mary Buffett & David Clark's** *Warren Buffett and the Interpretation of Financial Statements* (Scribner, 2008). Vektor implements one analytical interpretation of that framework — it does not represent the authors' or Warren Buffett's views. Financial statements are fetched from [**Financial Modeling Prep**](https://site.financialmodelingprep.com/developer/docs).

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for upstream attributions.
