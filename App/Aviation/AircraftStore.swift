import Foundation
import VektorAviation

/// User-saved aircraft profile. Persisted by `AircraftStore`
/// (= `PersistentStore<SavedAircraft>`) in UserDefaults as JSON.
/// `WBProfile` decodes the older box-envelope format, so profiles saved by
/// earlier versions still load (and get flagged as a plain rectangle).
typealias SavedAircraft = WBProfile
