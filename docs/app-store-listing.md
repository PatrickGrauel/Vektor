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

## Description — 2538/4000 characters

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

Requires macOS 14 Sonoma or later. Internet access is required for live rates, weather and financial data.
```

## What's New — unavailable for the first release

Apple does not expose this field for version 1.0.0's initial release. Leave it absent. This launch blurb is for a changelog or release announcement, **not** a Connect upload:

```text
Introducing Vektor: type calculations with live results, convert units and currencies, and save your sheets. Includes time zone, finance and aviation study tools.
```

162/4000 characters. For a later update, write the actual changes in that build; do not reuse a launch announcement.

## Private App Review notes — 1755/4000 bytes

```text
Vektor is a native macOS menu-bar notepad calculator. The panel opens at launch; click the Vektor menu-bar icon to show or hide it. No global summon hotkey is implemented.

Calculator test: create a sheet with Command-N and type:
rate = 85
hours = 12
subtotal = rate * hours
tax = 20% of subtotal
subtotal + tax
The final result is 1,224 (display grouping follows settings). Click the SHEET header to switch sheets.

The current build has purchase gating disabled: EntitlementManager.isUnlocked always returns true. StoreKit trial tracking and Settings purchase controls still exist. No purchase is needed to access this build. Public copy does not advertise a trial, unlock price or paid-feature gate.

Time zones, Finance, Aviation and METAR Map appear in the pane menu by default. Aviation and Map panes show a study/reference disclaimer on first use. Inline weather queries in Calculator do not show that gate. Stocks is hidden by default; enable it through the Vektor pane menu > Manage panes. Stocks requires a user-provided Financial Modeling Prep API key and coverage depends on its plan. The core calculator can be reviewed without that key.

Basic arithmetic and unit conversions work offline. Currency/crypto refreshes may start at launch; live weather and financial queries need internet access. Current endpoints include api.frankfurter.dev, open.er-api.com, openexchangerates.org (optional key), api.coingecko.com, aviationweather.gov, datis.clowd.io and financialmodelingprep.com. City lookup may use Apple's geocoder. Solar events are computed locally.

Aviation tools are for study/reference, not certified operational use. Stock scores are not investment recommendations. See the hosted privacy policy for third-party processing details.
```

## Remaining Connect fields

Primary category: **Productivity**. Secondary: **Utilities**. Copyright: **© 2026 Patrick Grauel**. Minimum OS: **macOS 14.0** (from project.yml). Complete the current age-rating questionnaire; 4+ is a candidate, not a verified rating.

Confirm real support and privacy destinations in the account. The earlier drafts disagree between vektor.app and GitHub Pages, and contain a placeholder email. Do not upload placeholders. Store price, territory availability, release timing and IAP state are not known from this repository. Keep public copy price-neutral until the final build and account configuration agree.

Do not select Data Not Collected solely from the privacy manifest. Review the release SDKs and providers' retention/processing, and correct the hosted policy; see the code audit. This package does not publish to App Store Connect.
