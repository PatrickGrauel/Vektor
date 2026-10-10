# Product claims checked against the shipping Mac target

Audit date: October 11, 2026. Scope: the macOS `Vektor` target sourced from `App/`, not `VektorPad/`. No application code was changed by this audit. No applicable `AGENTS.md` was found in the repository or its parent directories.

The supplied listing inputs were `docs/app-store-listing.md` and `APPSTORE_DESCRIPTION.md`. Both reviewed description drafts already fit the 4,000-character limit; factual accuracy and focus are the problems. The new canonical metadata replaces them, and Git history preserves earlier versions.

## Claims that need correction

| Existing claim or implication | What the Mac code actually does | Listing action |
| --- | --- | --- |
| “Free for 7 days, then unlock once”; “TRY IT FREE”; submission checklist with $9.99 IAP | `isUnlocked` unconditionally returns `true` in `App/Purchase/EntitlementManager.swift:53`. The seven-day timer, purchase listener and product ID still exist at lines 23–26 and 43–82. Settings still exposes status, Unlock and Restore Purchase at `App/Settings/SettingsView.swift:84`. The panel's paywall depends on `isUnlocked` at `App/MenuBarController.swift:413`, so it never appears. | Remove trial, price, unlock and subscription promises from the publishable copy. Choose a release pricing model separately and reconcile StoreKit/App Store Connect and Settings with the release build. An existing StoreKit fixture is not evidence of a live store price. |
| “One keystroke away”; instant global keyboard summon | There is no global show/hide hotkey registration in `App/`. `App/Settings/DocumentationView.swift:351` also explicitly lists it as missing. The menu-bar icon toggles the panel at `App/MenuBarController.swift:54`, and “Open Vektor” is a context-menu command at line 94. | Say “one click from your menu bar.” Record the real menu-bar click. In-app keyboard shortcuts remain valid; do not turn a context-menu key equivalent into a global hotkey claim. |
| “All local”; “the internet is used only to fetch …”; “only when you use the corresponding feature”; “no service preemptively” | `App/ContentView.swift:429` bootstraps live data when the interface appears. It starts FX and crypto streams at lines 227–260. `FXService.swift:194` fetches or refreshes its cache and starts polling at line 220. These streams run without requiring a visible conversion. | Use “Your sheets are stored on your Mac. No Vektor account or analytics. Live features contact third-party services.” Do not claim that launching Vektor makes no requests or that every request requires a contemporaneous explicit query. |
| “No account” without qualification alongside Stocks | Stocks is off by default (`App/ContentView.swift:400`), and its setup card requires an FMP account/key (`App/Stocks/StocksPane.swift:145`). Core calculator, units, currencies and aviation data work without that key (line 148). | “No Vektor account” is precise. Identify Stocks as optional and requiring the user's own third-party API key if mentioned. |
| “Enable Stocks in Preferences → Tools” | Pane visibility now lives in Vektor's pane menu → **Manage panes…**, `App/ContentView.swift:547` and lines 687–690. Settings has a Stocks configuration section only after the pane is enabled (`App/Settings/SettingsView.swift:124`). | Update review instructions and any screenshot setup instructions to the real menu path. |
| “Multiple documents … switch with ⌘L” | The sheet header opens the sheet popover (`App/Calculator/CalculatorPane.swift:113`). There is no ⌘L binding in the Mac calculator. Pinned sheet shortcuts are ⌘⇧1, ⌘⇧2, ⌘⇧3 (`CalculatorPane.swift:190`). | Say “switch sheets from the sheet header” or use the supported pinned shortcuts. |
| “Mix any units freely” | The engine uses math.js dimensional arithmetic; unrelated dimensions are not freely interchangeable. Missing-unit hints and aggregation safeguards are described in `Packages/VektorEngine/Sources/VektorEngine/NumiEngine.swift:14`. | Say “convert units” or “calculate with compatible units.” Use exact validated examples. |
| “Live currency” read as real-time market tick data | Default FX is ECB plus ExchangeRate-API (`App/ContentView.swift:199`). The primary feed uses daily ECB reference rates (`FXService.swift:353`); its gap fill is refreshed about daily (`FXService.swift:379`). Crypto has a five-minute stale interval (`CryptoService.swift:16`). | “Current exchange rates” is safer than “real-time rates.” Show the real rate/source display in the app and do not hard-code a conversion value into artwork. |
| Aviation data “for any airport”; map colors “every airport” | Reports depend on third-party availability. The map deliberately filters airports by tier, visible bounds and a render cap (`App/Map/MapPane.swift:12`). ATIS uses a separate D-ATIS endpoint (`MetarService.swift:299`). | Avoid universal coverage promises. Describe airport weather and a map with flight-category colors. Keep the aviation study/reference qualification adjacent to the feature. |
| “Stock scorecard for a public company” without limitations | FMP coverage is plan-dependent; some US companies, international listings and delisted tickers are not covered (`App/Stocks/FMPClient.swift:112`). A missing or invalid key, daily budget and unsupported ticker are distinct errors at lines 123–132. | Do not promise all public companies or a universal free stock-data service. Keep Stocks below the core notepad-calculator story. |

The old “Calculator for pilots & nerds” subtitle narrows the audience before communicating the everyday benefit. The previous promo also crams METAR, TAF, ATIS, time zones, density altitude and a map into one sentence, then contradicts their network use with “All local.” Lead with editable, line-by-line calculations; put specialist tools later.

## Code-backed inventory and launch behavior

| Capability | Evidence and practical limit |
| --- | --- |
| Menu-bar presence and reusable panel | Left click toggles; right click opens the menu (`App/MenuBarController.swift:33`, `54`). The panel is created once and reused (`:125`), preserving UI state while hidden. |
| Full-screen Spaces | A non-activating `NSPanel` uses `canJoinAllSpaces` and `fullScreenAuxiliary` (`MenuBarController.swift:117`) and becomes key without `NSApp.activate` (`:181`). This supports the “over full-screen apps” claim, subject to verifying the actual release capture on the chosen macOS version. |
| Always on top | Summoning elevates the panel; it falls back to normal level when focus is lost unless the setting is enabled (`MenuBarController.swift:204`). Settings offers the toggle, default false (`SettingsView.swift:16`, `67`). |
| Dock visibility | “Menu Bar Only Mode” is optional, default false (`SettingsView.swift:12`). Normal launches therefore may show a Dock icon as well as the menu-bar icon. The setting applies accessory activation policy (`MenuBarController.swift:303`); macOS may require a relaunch to refresh the Dock icon (`SettingsView.swift:72`). |
| Launch at login | Optional toggle using `SMAppService.mainApp`, `App/LaunchAtLogin.swift:6`. Launching the application itself shows its panel (`App/VektorApp.swift:60`). Do not claim a hidden-by-default startup. |
| Live line results | Content changes schedule evaluation after a 120 ms debounce (`App/Calculator/CalculatorPane.swift:251`). “As you type” is accurate; “instant” should not imply weather or rates have zero fetch latency. |
| Variables, headings, comments | Engine scope is document-based (`NumiEngine.swift:200`); `#` headings and `//` comments are display-only (`:217`), including trailing comments (`:225`). Variables are case-insensitive; existing engine tests cover this at `NumiEngineTests.swift:1336`. |
| Saved sheets | JSON documents live in the app's UserDefaults (`App/Calculator/DocumentStore.swift:70`, `261`). Text saves after 400 ms and pending saves flush at normal termination (`:109`, `250`). Sheets are pinnable (`:203`). A filtering method exists at `:184`, but the current popover has no search control. This is local persistence, not file-system document export or cloud sync. |
| Sheet navigation | Sheet header popover plus three pinned shortcuts, `CalculatorPane.swift:113`, `190`. ⌘N creates a new sheet (`App/ContentView.swift:598`). Pane ⌘1… shortcuts follow currently visible pane order (`:504`), so hiding Finance changes later pane shortcuts. |
| Initial interface | Calculator is the default pane unless restored within a ten-minute session window (`ContentView.swift:367`). One editable welcome sheet is created on first launch (`DocumentStore.swift:297`), with extra topic examples available from the new-sheet menu (`ContentView.swift:603`). |
| Extra panes | Calculator and Timezone are always visible (`ContentView.swift:407`); Finance, Aviation and METAR Map default enabled, Stocks disabled (`:394`). Pane visibility is configurable. |
| Finance | Eight tools: savings, retirement, loan, real estate, subscriptions, travel, tip and inflation (`App/Finance/FinancePane.swift:90`). Avoid presenting only the three older tools as the complete feature list. |
| Aviation | Weather, E6B and weight/balance tabs (`App/Aviation/AviationPane.swift:48`). Aviation and METAR Map have a first-use acceptance gate (`AviationPane.swift:15`; `App/Map/MapPane.swift:19`). Calculator METAR commands are handled independently (`NumiEngine.swift:258`) and do not pass through those pane gates. |
| macOS requirement | `project.yml` configures the `Vektor` target for macOS 14.0 and sources `App/`. `App/Resources/Info.plist:27` reads the deployment target for the minimum supported OS. |
| Export and sync limits | No dedicated TXT/CSV/PDF export, ShareLink, print workflow or results-to-clipboard action was found in the Mac `App/` calculator. Standard text editing/copying is available through NSTextView. Do not market document export, iCloud sync, or drag-out export. |

## Privacy policy corrections before submission

The manifest declares no tracking and an empty collected-data list (`App/Resources/PrivacyInfo.xcprivacy:7`, `18`), and the Mac app is sandboxed with a network-client entitlement (`App/Resources/Vektor.entitlements:5`). Those declarations alone do not establish how third-party providers retain or use requests. The final App Privacy answers must reflect the current build and the providers' practices.

`PRIVACY.md` is stale in several concrete places:

- **Line 23, “Keychain is never touched” without API keys:** the entitlement manager reads/writes a trial timestamp independently of API keys (`EntitlementManager.swift:43`, `185`, `205`). API-key migration also runs at app initialization (`VektorApp.swift:18`).
- **Line 59, no preemptive requests:** FX/crypto subscriptions and background polling start at launch. Describe that activity honestly.
- **Service table, missing fallback:** `open.er-api.com` is contacted by `FXService.swift:384`. Add ExchangeRate-API to the provider inventory; old review notes also omit it.
- **Line 41, NOAA Solar Calculator request:** sunrise/sunset uses the on-device NOAA-style equation (`Packages/VektorAviation/Sources/VektorAviation/SolarEvents.swift:3`, `34`; `NumiEngine.swift:1639`). The cited NOAA URL is an algorithm reference, not an endpoint contacted for each airport's sun times. Unknown place names may still be sent to Apple's geocoder (`CityResolver.swift:175`).
- **Line 16, “None … sent off-device”; line 47, documents “never sent anywhere”:** full sheet documents are not uploaded, but airport codes, city names and stock symbols extracted from queries are sent to their providers. Clarify this distinction; line 40 already acknowledges the typed city name sent to CLGeocoder.
- **Line 54, uninstall removes all data:** the entitlement code deliberately retains its Keychain trial stamp across reinstall (`EntitlementManager.swift:12`). Do not promise that uninstall removes Keychain items or that deleting the `.app` automatically wipes all stored data.

Recommended consumer-facing privacy sentence: **“Your sheets stay on your Mac. No Vektor account, analytics or ads. Live rates, weather, stock data and some place lookups use third-party services.”**

## Screenshot and video sample verification

An isolated SwiftPM test package under `/tmp/vektor-store-audit` imported the repository's current `VektorEngine` and evaluated the proposed samples with `vektor.precision = 2`, the Mac first-launch setting (`App/VektorApp.swift:29`). No application source or engine tests were modified. The final run completed successfully with zero failures. This validates deterministic engine output, not a finished visual capture.

| Frame/body | Verified result sequence, skipping heading lines |
| --- | --- |
| 01 · Project estimate: `rate = 85`, `hours = 12`, `subtotal = rate * hours`, `tax = 20% of subtotal`, `subtotal + tax` | `85.00` · `12.00` · `1 020.00` · `204.00` · `1 224.00` |
| 02 · Quick conversions: `10 mi in km`, `2.5 kg in lb`, `2 hours in minutes`, `15% off 240` | `16.09 km` · `5.51 lb` · `120.00 minutes` · `204.00` |
| 03 · Weekend budget: `guests = 6`, `dinner = 180`, `ride = 36`, `(dinner + ride) / guests` | `6.00` · `180.00` · `36.00` · `36.00` |
| 04 · Sheet popover | Reuse the exact 01–03 sheets; pin the desired sheets using the actual header pin button. This frame has no new math syntax. |
| 05 · Travel money: `100 EUR in USD`, `1500 THB in EUR`, `0.01 BTC in USD` | Network-derived values must come from a real app capture after rates load. The engine supports FX and crypto bridges (`NumiEngine.swift:145`, `155`); do not place test fixtures or fixed market prices into upload artwork. |
| 06 · Aviation study: `120 kt in km/h`, `29.92 inHg in hPa`, `2 hours in seconds` | `222.24 km / h` · `1 013.21 hPa` · `7 200.00 seconds`. An added `METAR KSFO` line requires a real current fetch and visible freshness indication. Do not synthesize a report. |

The estimate's `20% of subtotal` works with a variable; switching `hours = 12` to `hours = 16` is suitable for the video, after verifying the resulting values in the recorded UI.

Two older demonstration lines must not be reused:

- `100°F in °C` returns a syntax error. `100 degF in degC` works and returns `37.78 degC`; the former is still in the existing welcome seed (`DocumentStore.swift:312`).
- `2026-12-25 - 30 days` is interpreted as ordinary arithmetic and returns `1 959.00 days`, not a November date. It appears in the old README/listing examples. The supported explicit query `days between 2026-10-11 and 2026-12-25` returns `75.00`; use that form if date math is shown.

Other verified optional examples: `1430 Zulu in HKT` → `22:30 GMT+8`; `1400z in Tokyo` → `23:00 GMT+9`; `77/55 in hours` → `1h 24min`; `crosswind(270, 300, 10)` → `5.00`; `ground_speed(360, 100, 360, 20)` → `80.00`; `density_altitude(0, 30, 29.92)` → `1 800.00`. The aviation function results alone do not convey units in their gutter values; do not add units to the captured app UI.

Capture actual results at the intended precision; do not retouch numbers, weather, badges, source labels or UI controls to make them match this document.
