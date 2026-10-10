# Apple requirements and competitor evidence

Verified online on **11 October 2026**. These are the public specifications; App Store Connect processing and App Review still decide whether a submitted asset is accepted. Recheck linked references before upload.

## Text metadata

| Field | Current published limit | Application to Vektor |
| --- | --- | --- |
| Name | 2–30 characters | Keep the brand and one accurate functional term. |
| Subtitle | 30 characters | Complement the name. |
| Promotional text | 170 characters | Can change without a new version. |
| Keywords | 100 **bytes** in Connect reference | Use ASCII so character and byte counts agree. Each keyword must exceed two characters. |
| Description | 4,000 characters | Plain text; line breaks supported, HTML unsupported. |
| What’s New | 4,000 characters | Unavailable for the first version; required for subsequent versions. |
| Review notes | 4,000 bytes | Private to App Review; explain menu-bar launch, the Apple-confirmed free trial and lifetime unlock. |

Sources: [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/), [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/).

The marketing/search pages describe the keyword cap as 100 characters, while the Connect field reference says 100 bytes. The tooling uses the stricter byte limit. Do not infer that a non-ASCII keyword list with 100 visible characters fits.

## Search rules versus strategy

Apple identifies title, subtitle, keywords and categories as search relevance inputs; downloads, ratings and reviews also affect results. Its advice is to avoid keyword duplicates from the app name, subtitle and category, singular/plural duplication, filler, overly broad words, and special characters. Promotional text does not affect search ranking. Competitor names, irrelevant terms and unauthorized trademarks are forbidden in keywords. [App Store search](https://developer.apple.com/app-store/search/)

For this package, treating the name, subtitle and keyword field as one deduplicated word set is an ASO implementation choice. Apple does not promise exact phrase combinations, field weights, traffic, or a ranking advantage. Repetition in readable promotional text or description is not the same issue as duplicating indexed keywords. Measure search-source impressions and conversion in Connect after launch; the chosen terms are hypotheses until measured.

Apple’s product-page advice favors a clear opening sentence and concise features. It discourages description keyword stuffing and specific prices. [Creating your product page](https://developer.apple.com/app-store/product-page/)

## Mac screenshots

| Property | Required specification |
| --- | --- |
| Count | At least 1, up to 10 per device size |
| File | `.png`, `.jpg`, or `.jpeg` |
| Transparency | No alpha channels or transparency |
| Ratio | 16:10 |
| Accepted dimensions | 1280×800, 1440×900, 2560×1600, **2880×1800** |

Source: [Screenshot specifications, Mac](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

Use 2880×1800 as this kit’s production master. Opaque RGB PNG and sRGB are production choices, not additional requirements asserted by that page. Preserve real app UI; captions can surround it. Screenshots must show actual use; text/image overlays are allowed. Fictional data and rights to assets are required. Avoid unsupported features and misleading prices. [App Review Guidelines, 2.3](https://developer.apple.com/app-store/review/guidelines/)

## Mac App Preview technical specifications

| Property | Apple specification |
| --- | --- |
| Resolution / orientation | **1920×1080**, landscape |
| Count | Up to 3 per supported device size and language |
| Duration | 15–30 seconds |
| Maximum file size | 500 MB |
| H.264 container | `.mov`, `.m4v`, `.mp4` |
| H.264 video | Progressive; up to High Profile Level 4.0; maximum 30 fps; target 10–12 Mbps |
| H.264 audio | Stereo AAC 256 kbps; 44.1 or 48 kHz; all tracks enabled |
| Audio layout | One 2-channel L/R track, or two 1-channel L/R tracks |
| Alternative | ProRes 422 HQ only in `.mov`; progressive, no external references; ≤30 fps; ~220 Mbps VBR |
| ProRes audio | PCM 16/24/32-bit or AAC 256 kbps; stereo; 44.1/48 kHz |
| Default poster frame | 5 seconds; select a frame from the footage |
| Processing | May take up to 24 hours |

A different preview/screenshot aspect ratio moves the preview to **A Closer Look**. Mac’s specified preview is 16:9 while screenshots are 16:10; do not resize preview output to 2880×1800 to match the stills. [App preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/)

## App Preview editorial requirements

Only screen captures of the app itself may form the footage; explanatory overlays/narration are allowed. Avoid filmed hardware, people using the Mac, fabricated app animation, or scenes implying unsupported behavior. [App Review Guidelines, 2.3.4](https://developer.apple.com/app-store/review/guidelines/)

Apple recommends native-resolution UI, straightforward transitions, readable copy and a compelling footage-derived poster. Autoplay starts muted: the story must work without audio. Do not show specific prices or references that quickly date. Disclose featured paid features/subscriptions/login when applicable; use authorized material appropriate for all ages. For the trial-enabled release, disclose the free trial and one-time purchase required for continued access; do not display a fixed storefront price. A silent stereo AAC track is this kit’s conservative export choice; music is optional. [App Previews](https://developer.apple.com/app-store/app-previews/)

## Release metadata that needs verification outside source code

Age rating is generated from the questionnaire, with OS-specific and regional values. On macOS 26 the global tiers are 4+, 9+, 13+, 16+ and 18+; earlier versions use a different scale. A calculation tool with no objectionable content may qualify for 4+, but an old draft is not a completed rating questionnaire. Private local notes alone are not broadly distributed user-generated content under Apple’s descriptor. Answer for the shipped build. [Age ratings](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/)

Apple defines collection around off-device transmission retained beyond servicing a real-time request, including relevant third-party handling. On-device-only processing is not collection; absence of analytics does not alone prove “Data Not Collected.” Audit providers’ retained IP/request data, the release configuration and any SDKs before choosing that label. The draft claim that fetching third-party content automatically “doesn’t count” is too categorical. [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)

Privacy Policy URL and Support URL need real deployed destinations and contact details. Store price and purchase configuration are account state, not proved by a StoreKit fixture. Configure both the zero-price 60-day trial and paid lifetime-unlock IAPs to match the release build. First-release What’s New is unavailable, so preserve any launch blurb as a draft instead of an upload field.

## Competitor evidence and implications

### Soulver

The current official site and US store page identify **Soulver 4**, “Notepad, meet calculator.” It offers live answers beside text, variables, totals, sheets and cross-device coverage. Its site demonstrates units, currencies, time zones, loan/mortgage math, stock/weather data and trip planning. [Soulver website](https://soulver.app/), [US Mac product page](https://apps.apple.com/us/app/soulver-4/id1508732804?platform=mac)

QuickSoulver can be accessed from its app, menu bar or global hotkey. Therefore menu-bar access, live answer columns and plain-language arithmetic are not exclusive Vektor claims. [Official QuickSoulver documentation](https://documentation.soulver.app/whats-new)

### Numi

Numi’s official site presents a calculator for Mac, Windows and Linux with multiple languages. Its owner-maintained repository demonstrates natural-language discount, date and unit expressions; it lists timezone conversion, variables and plugins among Mac capabilities not yet implemented in its CLI. These CLI gaps must not be attributed to the Mac app. [Numi website](https://numi.app/), [Official repository](https://github.com/nikolaeu/numi)

A current Mac App Store listing for this Numi calculator could not be verified from the official site, repository or Apple search results during this check. Results for “Numi: Currency Scanner” concern a different developer’s iPhone app. Do not cite an old aggregator as current store evidence or claim Numi is absent in every storefront. Its current price, store ranking and store conversion are unverified.

### Positioning inference

The positioning wedge is aviation study/reference beside a focused Mac notepad workflow. Lead with useful math and conversions, then show a genuine METAR in the third screenshot; name aviation study tools in the opening copy. Soulver/Numi already demonstrate the general calculator capabilities, so those capabilities alone do not establish differentiation. This is a presentation/intent strategy, not proof Vektor is universally faster or more capable. Pursue accurate intent terms rather than stuffing Soulver/Numi into public metadata. No keyword volume, competitor search rank or ranking uplift was obtained in this research.
