import Foundation
import Security
import os

/// Thin wrapper around `SecItem*` for storing string secrets in the
/// macOS Keychain. Vektor uses this for the two API keys that previously
/// lived in `UserDefaults` (FMP for the Stocks pane, OpenExchangeRates
/// for live FX rates).
///
/// Items are partitioned by Vektor's app sandbox automatically — the
/// service identifier below is informational. No keychain-access-groups
/// entitlement is required because we never share with another app.
///
/// The `changeNotification` is posted on every successful `set(_:for:)`.
/// `@KeychainStored` property wrappers observe it so a write in one view
/// updates a reader in another — mirroring the cross-view sync that
/// `@AppStorage` got for free via UserDefaults's KVO.
enum KeychainStorage {
    static let changeNotification = Notification.Name("vektor.keychain.changed")

    /// `userInfo` key on `changeNotification`. Value is the account
    /// string that just changed.
    static let changeNotificationKeyInfoKey = "key"

    /// Service attribute on every stored item. macOS surfaces this
    /// string in its "Vektor wants to use your confidential information
    /// stored in '<service>'" prompt — using the product name reads
    /// cleanly there, where the bundle ID (kept at the legacy
    /// `app.vektor.Vektor` for data continuity) would not.
    ///
    /// Renamed from `app.vektor.Vektor` in 1.0.0. Items written under the
    /// old service are now orphaned; users with an existing FMP /
    /// OpenExchangeRates key re-paste once and the new entries land
    /// under `Vektor`. The orphan entries are visible in Keychain
    /// Access.app and can be deleted manually if desired.
    private static let service = "Vektor"

    // MARK: - Presence flag
    //
    // macOS prompts the user every time an app whose signature has
    // changed reads from the Keychain. In development with ad-hoc
    // signing that's every rebuild — so any code path that even
    // *checks* "is there a key stored?" triggers a prompt before
    // the user has typed anything. To answer that question without
    // touching the Keychain, every successful `set(_:for:)` /
    // `delete(_:)` mirrors a Boolean into `UserDefaults` at key
    // `<account>.present`. Views and singletons read that Boolean
    // for "is the key set?" decisions. The actual Keychain value
    // is read only at the moment we need to USE it (FMP API call,
    // QuoteService fetch), and only when `hasKey(_:)` confirms a
    // value exists.

    static func hasKey(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: "\(key).present")
    }

    private static func setPresenceFlag(_ key: String, value: Bool) {
        UserDefaults.standard.set(value, forKey: "\(key).present")
    }

    // MARK: - CRUD

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    /// Stores `value` (or deletes the item when `value` is empty).
    /// Returns `true` only when the Keychain actually holds the intended
    /// final state — callers that must not lose the secret (migration,
    /// trial stamp) check this before discarding their source copy.
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        // Idempotent: delete any existing entry first.
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let deleteStatus = SecItemDelete(q as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            logger.error("SecItemDelete(\(key, privacy: .public)) failed: \(deleteStatus)")
        }

        var succeeded = true
        if !value.isEmpty {
            var add = q
            add[kSecValueData as String] = Data(value.utf8)
            // NOTE: deliberately no `kSecAttrAccessible` here. That
            // attribute is only valid for data-protection-keychain items;
            // on the macOS file-based keychain it is ignored at best and
            // on several OS versions makes `SecItemAdd` fail with
            // `errSecParam`. Sandboxed file-keychain items are already
            // device-bound and ACL'd to this app.
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("SecItemAdd(\(key, privacy: .public)) failed: \(addStatus)")
                succeeded = false
            }
        }

        // Mirror presence into UserDefaults so other call sites can
        // ask "is the key set?" without triggering a Keychain read.
        // On a failed add the item is GONE (delete-then-add), so the
        // flag must say false — a stale `true` would make readers
        // believe a key exists that doesn't.
        setPresenceFlag(key, value: !value.isEmpty && succeeded)

        // Notify observers regardless of outcome — empty means "deleted",
        // failure means "changed to absent"; views may want to react.
        NotificationCenter.default.post(
            name: changeNotification,
            object: nil,
            userInfo: [changeNotificationKeyInfoKey: key]
        )
        return succeeded
    }

    private static let logger = Logger(subsystem: "app.vektor.Vektor", category: "keychain")

    static func delete(_ key: String) {
        set("", for: key)
    }

    // MARK: - Migration

    /// On launch, copy a UserDefaults-stored secret into the Keychain
    /// (if not already migrated) and clear the UserDefaults entry. Safe
    /// to call on every launch — becomes a no-op after the first
    /// successful pass. Logs the migration so the user can audit in
    /// Console.app if needed.
    static func migrateFromUserDefaults(_ key: String) {
        // Cheap short-circuit FIRST: if UserDefaults holds nothing there
        // is nothing to migrate — and we avoid a `SecItemCopyMatching`
        // (and its possible signature-change prompt) on every launch.
        guard let stored = UserDefaults.standard.string(forKey: key),
              !stored.isEmpty,
              get(key) == nil
        else { return }
        // Only destroy the UserDefaults copy once the Keychain write is
        // CONFIRMED — otherwise a failed add would delete the user's
        // only copy of the secret.
        if set(stored, for: key) {
            UserDefaults.standard.removeObject(forKey: key)
            logger.notice("migrated \(key, privacy: .public) from UserDefaults to Keychain")
        } else {
            logger.error("migration of \(key, privacy: .public) failed — UserDefaults copy retained")
        }
    }
}
