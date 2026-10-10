# Vektor product-page direction and capture plan

Prepared for the macOS `App/` target on **11 October 2026**, using both existing listing drafts and the implementation. This is the launch plan, not a claim of measured search performance. [Canonical metadata](../app-store-listing.md) · [machine-readable copy](metadata.json) · [Apple evidence](apple-specs.md) · [code audit](code-audit.md).

## Positioning

**Vektor keeps the thought and the calculation on the same page, within reach of your current Mac work.** Its primary audience is people who repeatedly do small pieces of math while doing something else: freelancers estimating a project, people splitting costs, travelers comparing money and measurements, and technical workers checking units. They need a scratchpad they can revisit, rather than a new spreadsheet for each question.

The secondary audience is aviation students and enthusiasts who appreciate familiar speed/pressure conversions and weather queries. Aviation is a credible specialist reason to choose Vektor; leading every frame with cockpit terminology would make a broadly useful calculator look inaccessible. Stocks stays in the description as an optional tool, because API-key setup and provider coverage introduce friction before the core value is apparent.

**The first three seconds:** the name says “Notepad Calculator”; the subtitle explains menu-bar math, units and currency; the first screenshot shows a complete six-line project estimate with a clear final result. A viewer should immediately understand “I type my own numbers; it does the math beside my notes.” The screenshot headline is **Write the math. See the answer.** The first sentence of the description carries the same idea.

Sell useful retained work: a project estimate that can change, a shared-cost sheet whose inputs can be edited, and a conversion list whose answer column is visible. Do not lead with six module names, broad “plain English understands anything” claims, or a long developer-origin story. The current disabled paywall cannot support “free for seven days, then unlock once.” Price and purchase claims stay out of the public package.

## Competing in search and on the page

Soulver and Numi already demonstrate natural-language math, variables and conversions. Soulver's current QuickSoulver also provides menu-bar and global-hotkey access. These are category requirements, not exclusive Vektor inventions. Current competitor capabilities and research limitations are linked in [Apple/competitor evidence](apple-specs.md#competitor-evidence-and-implications).

| Buyer intent | Our coverage | What the page proves |
| --- | --- | --- |
| notepad calculator / menu bar calculator | Name + subtitle | A complete sheet of typed calculations; menu-bar click in the preview |
| budget calculator / percentage calculator | Keywords + name | An estimate with a percentage and a shared-cost sheet |
| unit/currency conversion | Subtitle + `convert` keyword | Simple conversions; a genuine provider-backed rate screenshot |
| offline scratchpad / math notes | Keywords + subtitle | Saved local sheets and deterministic math; offline applies to basic math and units |
| aviation calculator / METAR / E6B | Accurate specialist keywords | The last screenshot and description, explicitly for study/reference |

This is a route to more relevant intent, not a promise to outrank an established app. The keyword set is a launch hypothesis without volume, rank or revenue data. Avoid Soulver/Numi, competitor trademarks, “best,” prices, duplicated category terms and alternate plurals in indexed fields. Readable description and promo text may repeat functional words; keyword deduplication applies to the indexed set.

The conversion advantage to pursue is clarity: small, recognizable sheets, one benefit per frame, readable real results, and a visible reason to return to saved work. Specialist depth comes after the general use case. Do not claim more natural-language coverage than Soulver, a global shortcut Vektor lacks, exclusive menu-bar access, or guaranteed savings against an unverified competitor price.

After launch, record search-source impressions, product-page views and downloads in App Store Connect by territory and period. Inspect available source-level conversion rather than mixing search and browsing. Establish a baseline covering a normal full week, then change one element per comparable period (for example screenshot 1, then subtitle). Small samples, seasonality and release effects prevent causal conclusions. Do not assume iOS Product Page Optimization features are available for this Mac listing; use the controls the actual account exposes. Keep a dated change log and retain the original metadata JSON.

## Screenshot production direction

Produce **six 2880×1800 opaque RGB PNGs**, in the order below. Apple allows 1–10 Mac screenshots and also accepts smaller prescribed 16:10 sizes. These six masters use the warm cream, navy ink and burnt-orange palette in `App/Theme.swift`, with system type and real app captures. The renderer supplies a restrained heading band and preserves the complete capture below it. It draws no app controls or results.

Use a clean macOS capture account with no personal notes or private background windows. Build the current `Vektor` scheme, not `VektorPad`. Keep Calculator selected; use light appearance, precision 2 and digit grouping on. The app's text size is fixed, so size the actual panel to approximately **1280×600 logical points on a 2× Retina display**. A raw image around 2560×1200 preserves the 26 px calculator type at near-native size in the finished frame. Keep the editor/results divider near the center and verify every result fits. Apple does not mandate the renderer's 24 px minimum readable type; it is our production quality check.

Use the native window capture for a plain panel. For a popover, use a single real screen-region capture enclosing both panel and popover; a window selector can capture only one surface. Do not paste a separately captured popover into the frame. Capture instructions and scripts are in [tooling.md](tooling.md). The master source is [screenshots.json](screenshots.json), including exact text, output names and capture notes.

| Order / file stem | Headline | Subline | Visible proof |
| --- | --- | --- | --- |
| 01-project-estimate | Write the math. See the answer. | Keep your notes and calculations on the same sheet. | Named inputs, percent calculation, 1 224.00 final result |
| 02-conversions | Conversions, in plain language. | Units, percentages and discounts, right where you type. | Four different useful typed expressions |
| 03-changing-inputs | Change a number. Rethink the plan. | Variables keep the related calculations up to date. | Six guests share 216, final result 36.00 |
| 04-saved-sheets | Your useful math, kept together. | Save separate sheets. Pin the ones you return to. | Real SHEET popover and pinned sheet titles |
| 05-travel-money | Compare currencies in one place. | Live rates for travel money, with the source in view. | Real EUR/USD, THB/EUR and BTC/USD outputs and provider source |
| 06-aviation-study | For aviation study, too. | Weather reports and conversions for study and reference. | Unit conversions and a genuine METAR with freshness |

### 1. Project estimate

Create with ⌘N; paste exactly:

```text
# Project estimate
rate = 85
hours = 12
subtotal = rate * hours
tax = 20% of subtotal
subtotal + tax
```

Verified using the current engine at precision 2: 85.00, 12.00, 1 020.00, 204.00, 1 224.00. The `#` title has no result. Preserve the actual spacing/unit formatting produced by the app. Pin this sheet for frame 4.

### 2. Quick conversions

```text
# Quick conversions
10 mi in km
2.5 kg in lb
2 hours in minutes
15% off 240
```

Verified numeric values: 16.09 km, 5.51 lb, 120.00 minutes, 204.00. Pin this sheet. These are deterministic and need no live feed.

### 3. Editable weekend budget

```text
# Weekend budget
guests = 6
dinner = 180
ride = 36
(dinner + ride) / guests
```

Verified outputs: 6.00, 180.00, 36.00, 36.00. For the video, start with four guests and change only the `4` to `6`; the final cost changes from 54.00 to 36.00. The still shows the six-person end state. Pin it for frame 4.

### 4. Saved sheets

Do not type another document: use the exact Weekend budget body from frame 3. Create and pin the three named sheets from frames 1–3. Select Weekend budget, click the **SHEET** header, and capture the actual popover showing those titles and their pin states. No ⌘L shortcut exists. Do not delete a user's documents to clean the capture; use the dedicated capture account.

### 5. Travel money

```text
# Travel money
100 EUR in USD
1500 THB in EUR
0.01 BTC in USD
```

Connect to the internet and wait for actual rate updates. Leave the rate-source annotation enabled. Inspect the annotation and sanity-check every result before recording; never publish 1:1 startup fallbacks, an offline placeholder or a fabricated rate. Settings has no live-rate status panel. No exact output is specified because rates change. Check any tiny source annotation manually at the store's reduced viewing size.

### 6. Aviation study

```text
# Aviation study
120 kt in km/h
29.92 inHg in hPa
2 hours in seconds
METAR KSFO
```

Verified deterministic numeric values: 222.24 km/h, 1 013.21 hPa, 7 200.00 seconds. Wait for a genuine KSFO report and preserve its freshness/status indicator. Weather availability and issuance time vary. Calculator's inline weather query does not show the separate Aviation/Map disclaimer gate; the caption must still say study/reference. Do not imply flight safety, certification, a clearance or approved runway selection.

If the complete report does not fit legibly, remove the METAR line and change the manifest subline to **Speed, pressure and time conversions for study and reference.** This is a documented fallback, not permission to hide stale/error status or invent weather. Revalidate and render the changed manifest.

## Submission readiness

Metadata and capture recipes are ready to review. Raw screenshots, final uploaded frames and a recorded video are separate production outputs; tooling tests use conspicuously synthetic fixtures and do not create uploadable app evidence. Record the exact release build/commit alongside captures before rendering.

Before submission, reconcile the disabled gate with the remaining trial/unlock controls and the actual Connect IAP configuration; correct the hosted privacy policy; verify support/privacy URLs and contact email; complete age-rating and privacy questionnaires for the shipped build; inspect all images and the encoded video; upload screenshots in filename order and select the preview's actual poster frame. None of these account facts can be inferred from source. See [code-audit.md](code-audit.md) for the concrete draft contradictions.
