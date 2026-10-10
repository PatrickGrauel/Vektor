# Vektor — Mac App Store listing

Canonical copy generated from [metadata.json](app-store/metadata.json). Locale **en-US**; version **1.0.0**. Apple requirements verified **11 October 2026**.

Run `python3 scripts/app-store/validate-metadata.py --check-listing docs/app-store-listing.md` after changes. [Positioning and capture recipes](app-store/product-page.md), [preview storyboard](app-store/app-preview.md), [Apple sources](app-store/apple-specs.md), [code audit](app-store/code-audit.md), [production tooling](app-store/tooling.md).

## App name — 26/30 characters

```text
Vektor: Notepad Calculator
```

## Subtitle — 30/30 characters

```text
Menu bar math, units, currency
```

## Promotional text — 151/170 characters

```text
Everyday math and pilot study, together. Type calculations, convert currencies and retrieve METAR weather, with aviation tools for study and reference.
```

## Keywords — 87/100 bytes

```text
convert,percentage,timezone,offline,finance,aviation,metar,e6b,taf,crosswind,zulu,pilot
```

## Description — 2795/4000 characters

```text
Keep the thought and the calculation on the same page. Vektor is a menu-bar notepad calculator for your Mac, with aviation tools for study and reference: type math beside your notes and see results as you write.

Estimate a project, split a dinner, convert a measurement, or compare a travel budget. Open Vektor from the menu bar, do the math, and return to your work.

WRITE IT AS A SHEET

Mix calculations, variables, headings and comments. Change an input and the related results update. Keep separate sheets for separate projects, pin the ones you use often, and return to them later. Sheets are saved locally on your Mac.

Try a project estimate:
rate = 85
hours = 12
subtotal = rate * hours
tax = 20% of subtotal
subtotal + tax

CONVERT IN PLACE

Type familiar expressions such as:
10 mi in km
2.5 kg in lb
15% off 240
100 EUR in USD

Convert units, calculate percentages, and work with currency and crypto rates. Live data needs an internet connection; basic math and unit conversions work offline. Rates come from third-party providers and may be cached or delayed.

MADE FOR YOUR MAC

Click the menu-bar icon to show or hide Vektor. Keep its panel beside your work, including over a full-screen app. An Always on top option, light and dark appearances, adjustable decimal precision, and launch at login help it fit your workflow. Menu Bar Only Mode is optional.

MORE TOOLS WHEN YOU NEED THEM

Time zones: compare cities and convert times.
Finance: explore loan payments, savings goals, travel budgets, tip and split, and other scenarios.
Aviation: retrieve METAR, TAF and ATIS reports, explore the weather map, and use E6B tools for study and reference. Aviation features are not certified for flight planning, navigation or aircraft operation. Cross-check official sources and your aircraft documentation.
Stocks: an optional company scorecard using third-party financial statements. Enable it in Manage panes and provide your own Financial Modeling Prep API key. Coverage depends on your provider plan. Scores are not investment advice or buy/sell recommendations.

KEEP YOUR WORK LOCAL

No Vektor account is required. There are no analytics or ads in the app. Sheets and settings are stored on your Mac. Live features contact third-party services; rate refreshes can run at launch and in the background. Optional API keys are stored in the macOS Keychain and sent to their respective providers.

TRY IT FOR 60 DAYS

Start a 60-day free trial through Apple's purchase sheet. It does not renew or charge automatically. After the trial, a one-time in-app purchase unlocks continued access to Vektor's calculator and tools. No subscription. Your saved sheets remain on your Mac.

Requires macOS 14 Sonoma or later. Internet access is required for live rates, weather and financial data.
```

## What's New — unavailable for the first release

Apple does not expose this field for version 1.0.0's initial release. Leave it absent. This launch blurb is for a changelog or release announcement, **not** a Connect upload:

```text
Introducing Vektor: type calculations with live results, convert units and currencies, and save your sheets. Includes time zone, finance and aviation study tools.
```

162/4000 characters. For a later update, write the actual changes in that build; do not reuse a launch announcement.

## Private App Review notes — 2592/4000 bytes

```text
Vektor is a native macOS menu-bar notepad calculator. The panel opens at launch; click the Vektor menu-bar icon to show or hide it. No global summon hotkey is implemented.

Calculator test: create a sheet with Command-N and type:
rate = 85
hours = 12
subtotal = rate * hours
tax = 20% of subtotal
subtotal + tax
The final result is 1,224 (display grouping follows settings). Click the SHEET header to switch sheets.

Purchases: the app is free to download. At first use, the paywall offers Start 60-day free trial (zero-price non-consumable app.vektor.Vektor.trial60, localized name 60-day Trial) and a one-time lifetime unlock (non-consumable app.vektor.Vektor.unlock). Both open Apple's native purchase sheet. The StoreKit price of the lifetime unlock, trial duration and loss of calculator/tool access after expiry are disclosed before starting. There is no subscription or automatic charge. The trial begins at the verified trial transaction originalPurchaseDate and ends 60 days later. Restore Purchases retrieves Apple entitlements; a restored trial retains its original end date. Saved sheets are retained after expiry.

Review purchases from the paywall or Settings > Vektor Calculator. Start the free trial to review all core tools, or test the lifetime unlock in the review purchase environment. Reopen Settings > Vektor Calculator to restore. No Vektor login or third-party key is required for the core trial.

Time zones, Finance, Aviation and METAR Map appear in the pane menu by default. Aviation and Map panes show a study/reference disclaimer on first use. Inline weather queries in Calculator do not show that gate. Stocks is hidden by default; enable it through the Vektor pane menu > Manage panes. Stocks requires a user-provided Financial Modeling Prep API key and coverage depends on its plan. The core calculator can be reviewed without that key.

Basic arithmetic and unit conversions work offline. Currency/crypto refreshes may start at launch; live weather and financial queries need internet access. Current endpoints include api.frankfurter.dev, open.er-api.com, openexchangerates.org (optional key), api.coingecko.com, aviationweather.gov, datis.clowd.io and financialmodelingprep.com. Place search and map display may use Apple Maps/geocoding. Solar events are computed locally. Optional Calendar export asks for calendar permission and saves only the event the user confirms.

Aviation tools are for study/reference, not certified operational use. Stock scores are not investment recommendations. See the hosted privacy policy for third-party processing details.
```

## Remaining Connect fields

Primary category: **Productivity**. Secondary: **Utilities**. Copyright: **© 2026 Patrick Grauel**. Minimum OS: **macOS 14.0** (from project.yml). Complete the current age-rating questionnaire; 4+ is a candidate, not a verified rating.

Use the working [privacy policy](https://raw.githubusercontent.com/PatrickGrauel/Vektor/main/PRIVACY.md) and [support page](https://github.com/PatrickGrauel/Vektor/issues), and publish the current policy before submission. Configure the free 60-day Trial and paid lifetime unlock in Connect; the intended US unlock price is $25.00. Live prices, territory availability, signing and IAP review state require account setup. See [release readiness](app-store/release-readiness.md) for the remaining steps.

Do not select Data Not Collected solely from the privacy manifest. Review release behavior and providers' retention/processing; see the privacy policy and release readiness checklist. This package does not publish to App Store Connect.
