# Vektor Privacy Policy

_Last updated: October 11, 2026_

Vektor is a native macOS calculator operated by Patrick Grauel, an individual developer ("we" / "us"). This policy explains the data stored by Vektor and the services used for purchases, live information, maps and place lookups.

## Your work stays on your Mac

Vektor has no Vektor account, advertising, analytics SDK or developer-operated service that receives your calculation sheets. It does not track you across other apps or websites or sell your data.

Vektor stores the following locally:

- **Calculation sheets, settings and saved inputs**, including pinned cities, finance scenarios and stock watchlists, in the app's preferences (`UserDefaults`).
- **Cached information**, including exchange rates, crypto prices, aviation weather, place lookups and stock data, on disk in the app's sandbox container.
- **Optional API keys** for OpenExchangeRates and Financial Modeling Prep in the macOS Keychain. A presence flag is stored in preferences; the key itself is read when needed by its service. Older preferences-based keys are migrated to Keychain when possible.
- **Purchase and trial information** provided by Apple's StoreKit, used on your Mac to determine access. The free trial begins when you confirm its zero-cost purchase through Apple. Trial dates come from that transaction; Vektor does not create a separate device identifier or local trial clock.

Preferences and caches are normally inside `~/Library/Containers/app.vektor.Vektor/`. Keychain items are stored separately by macOS, under the service name `Vektor`; older versions may have used `app.vektor.Vektor`. macOS may ask permission when Vektor accesses Keychain items. API-key entries and legacy trial records from older versions can survive removal and reinstallation of the app.

Vektor does not upload complete sheets. A live query can send information taken from a line, such as an airport code, city name or stock symbol, to the relevant service below.

## Services Vektor uses

Requests travel directly from your Mac to the provider. Providers receive normal network metadata, including your IP address, and may retain or process requests under their own policies and terms. We do not control their retention. API keys are sent only to the provider that issued them.

| Feature | Recipient | Information used in the request |
| --- | --- | --- |
| METAR / TAF weather | [NOAA Aviation Weather Center](https://aviationweather.gov/) | The airport code you query. |
| Weather map reports | [NOAA Aviation Weather Center](https://aviationweather.gov/) | The visible map's latitude/longitude bounds. |
| ATIS | [datis.clowd.io](https://datis.clowd.io/) | The airport code you query. |
| Default currency rates | [Frankfurter](https://www.frankfurter.dev/) and [ExchangeRate-API](https://www.exchangerate-api.com/) (`open.er-api.com`) | Requests for exchange-rate tables with USD as the base. Your calculation amount and complete line are not sent. |
| Optional currency-rate provider | [OpenExchangeRates](https://openexchangerates.org/) | Your API key and a request for the rate table. |
| Crypto rates | [CoinGecko](https://www.coingecko.com/) | A request for the app's supported crypto price table in USD. Your calculation amount and complete line are not sent. |
| Stocks | [Financial Modeling Prep](https://site.financialmodelingprep.com/) | Your API key, the ticker or search text, and the financial-data request. |
| Place search, time zones and sun-query place resolution | Apple's geocoding and Maps services | Place names or search fragments you enter; selected place coordinates may be reverse-geocoded for their time zone. Built-in or cached lookups can be resolved locally. |
| Map display | Apple Maps | Requests for map content corresponding to the displayed region. |
| Trial and lifetime unlock | Apple App Store / StoreKit | Product requests, purchase, restoration and entitlement checks. Apple handles the Apple Account and payment information; Vektor does not receive your card details. |

Apple's services are covered by [Apple's privacy information](https://www.apple.com/legal/privacy/). The linked provider sites describe their respective services and policies.

**Sunrise and sunset are calculated on your Mac.** Vektor does not send a sun-events request to NOAA. Resolving the place named in a sun query can use Apple's geocoder as described above.

**Refreshes can happen while Vektor is running.** Currency and crypto rate requests may begin at launch and refresh in the background, even without a conversion on screen. Previously requested airport weather can also refresh automatically. Closing the panel does not quit Vektor; quitting the app ends its activity.

## Calendar and clipboard actions

When you choose to save a time-zone meeting to Calendar, Vektor asks macOS for calendar access, reads the writable calendar list and writes the event you confirm. Its title, time, location, URL, notes and reminder are saved to your chosen calendar. If that calendar uses iCloud or another provider, the calendar service may sync the event according to your account settings. Vektor does not send calendar contents to a developer-operated server.

When you choose to copy text or a scheduling snippet, Vektor writes it to the macOS clipboard. Other apps with clipboard access may be able to read it.

Vektor does not request your device's current location. Coordinates used by maps, time zones and sun calculations come from places you enter or select and bundled airport information.

## Retention and your choices

- Basic arithmetic and unit conversion work offline. Live rates, weather, stocks, Maps and uncached place searches need network access.
- Optional API keys can be removed in the app's settings. Stocks requires your own Financial Modeling Prep key.
- You can delete individual sheets and saved inputs in the app. To remove local preferences and caches, quit Vektor and remove its sandbox container. Deleting the `.app` alone does not guarantee that preferences, caches or Keychain items are removed.
- Keychain items can be removed separately using Keychain Access. This does not cancel or erase a purchase recorded by Apple. Apple controls its purchase history and payment-data retention.
- Removing local data does not remove requests already received by providers or events already saved to Calendar. Manage those through the relevant provider or calendar account.

## Children

Vektor is a general-purpose calculator and is not marketed as a children's app. It does not create user profiles or collect analytics.

## Changes and contact

We may update this policy as Vektor changes. The policy hosted at the Privacy Policy URL in the App Store listing is the current published version. For questions, contact the developer through [Vektor support](https://github.com/PatrickGrauel/Vektor/issues). GitHub issues are public: do not post API keys, payment information or other private details. The App Store listing may also provide an additional contact method.
