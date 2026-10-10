# Mac App Store release readiness

Prepared **11 October 2026** for the macOS `App/` target. This is the release handoff, not evidence of App Store Connect setup, signing, submission or approval.

## Purchase configuration

The app is free to download. A user explicitly starts a 60-day free trial through Apple's purchase sheet or buys a lifetime unlock. The trial does not renew or charge automatically. Access ends 60 days after the verified trial transaction's original purchase date (`originalPurchaseDate`); restoration preserves that date. A lifetime unlock allows continued calculator/tool access. Expiry does not delete saved sheets.

| Product | App Store Connect type | Required configuration |
| --- | --- | --- |
| `app.vektor.Vektor.trial60` | Non-consumable | Display name **60-day Trial**; zero price; available in the intended app territories. |
| `app.vektor.Vektor.unlock` | Non-consumable | **Vektor Lifetime Unlock**; intended US price **$25.00**; configure the actual storefront prices and availability. |

Apple's non-subscription trial guidance calls for a zero-price non-consumable and pre-trial disclosure of duration, access lost and the downstream unlock charge. Vektor displays Apple's localized unlock price before starting the trial. `Vektor.storekit` is a local test catalog; its prices and IDs do not create products in Connect. [App Review Guidelines, 3.1.1](https://developer.apple.com/app-store/review/guidelines/)

## Remaining account and release steps

- [ ] **Business:** active Developer Program membership and Paid Apps Agreement; complete banking and tax information. The Account Holder must accept the agreement. Confirm EU trader status/contact verification and any regional compliance prompts for the territories chosen. [Agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/), [Connect sections](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-sections/).
- [ ] **App record and both IAPs:** confirm the account's macOS app record uses `app.vektor.Vektor`; set download price to free; create both products above with localizations, prices, territory availability, review screenshots and review notes. Attach both first non-consumables to the same submission as the app version. [Submit an In-App Purchase](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/).
- [ ] **Signing and upload:** use the correct team and Mac App Store distribution provisioning through Xcode; archive the Release scheme without a local StoreKit configuration, validate, upload and inspect the processed build. An ad-hoc build or development DMG is not the submission archive. Confirm version/build numbers and embedded resources, privacy manifest, sandbox/network/calendar entitlements and app icon.
- [ ] **Public policy/support:** publish the updated `PRIVACY.md` before release and confirm the app and Connect use the same working destinations. The existing [raw privacy URL](https://raw.githubusercontent.com/PatrickGrauel/Vektor/main/PRIVACY.md) and [support issues page](https://github.com/PatrickGrauel/Vektor/issues) returned HTTP 200 anonymously on 11 October 2026. The raw policy is plain Markdown. These checks do not publish the local changes. Recheck after pushing. Public issues need a GitHub account to post; supply an additional private contact method if needed, without placeholder details.
- [ ] **Privacy and compliance:** complete App Privacy answers from the release behavior and relevant provider retention; do not infer “Data Not Collected” solely from the manifest. Include live-service query parameters, Maps/place lookup, StoreKit and optional Calendar export in the assessment. Complete age-rating and export-compliance questions; validate the existing non-exempt-encryption declaration for the submitted build. [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).
- [ ] **Terms:** retain Apple's standard EULA for this release. `EULA.md` is a custom draft and must not be uploaded as an active replacement without completing developer contact/address details and explicitly selecting it for the intended regions. [Custom license agreements](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/).
- [ ] **Store assets:** capture the final build in use, including real rates/weather where shown; generate and inspect the opaque Mac screenshots. Captions must disclose the free trial and one-time unlock. If uploading a preview, record genuine app footage, include that disclosure and inspect the encoded video/poster. The repository's capture recipes and tooling fixtures are not finished store assets.
- [ ] **Review metadata:** upload the validated fields from `metadata.json`, select the correct build, supply an active App Review contact and the purchase/navigation notes, then choose the intended release timing. Verify screenshots and IAPs are included before submission.

## Purchase validation still required against Apple

The 22 local purchase tests, 15 metadata/preview tests and 7 screenshot-renderer tests passed. A document persistence smoke check confirmed that closing the editor saves the final typing burst before the 400 ms debounce. An unsigned universal Release build succeeded; its privacy manifest, calendar usage text, bundled datasets and license notices were checked, and the local StoreKit catalog is excluded from the app bundle. This does not validate signing or the real account products.

Run Xcode's **Vektor StoreKit** scheme for local purchase scenarios, then repeat using the **Vektor** scheme on Apple's sandbox or TestFlight with the local fixture disabled. Local tests cannot prove that the real account products load. On macOS, a development app's sandbox sign-in is available in App Store settings after the first purchase attempt. Account product changes may take time to propagate. [Sandbox testing](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox).

Record results for: new account with no entitlement; explicit free-trial confirmation; cancellation; pending/Ask to Buy; unavailable products/network error and retry; active trial; exact 60-day expiry while running; lifetime unlock; relaunch; reinstall/second Mac using the same Apple Account; Restore Purchases; expired trial restore without restarting it; revoked/refunded purchases; unverified transactions; and a different Apple Account. Verify Settings and the paywall agree, dates/prices are localized, and sheets survive expiry. Test Calendar export both with access granted and denied.

## Bundled attribution

`App/Resources/ThirdPartyNotices.txt` contains Vektor's MIT license, math.js's full Apache 2.0 license/NOTICE, the installed runtime dependencies' license texts and OurAirports' Unlicense/attribution. Confirm it is present and readable through Settings in the archive. Regenerate its package notices whenever the bundled JS dependencies change; versions must agree with `JS/package-lock.json` and the actual math.js bundle. The dataset attribution comes from the [official OurAirports repository](https://github.com/davidmegginson/ourairports-data).
