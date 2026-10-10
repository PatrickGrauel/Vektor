import SwiftUI
import Combine

/// `@AppStorage`-shaped property wrapper that backs its value in the
/// macOS Keychain instead of `UserDefaults`. Use for secrets: API keys,
/// tokens, anything you'd be uncomfortable seeing in a plain-text
/// preferences file.
///
/// Cross-view sync: writes to one `@KeychainStored` instance are picked
/// up by every other instance bound to the same key, via a
/// `KeychainStorage.changeNotification` observer.
///
/// Usage mirrors `@AppStorage`:
/// ```
/// @KeychainStored("vektor.stocks.fmpApiKey") private var apiKey: String = ""
/// ```
@propertyWrapper
struct KeychainStored: DynamicProperty {
    @StateObject private var store: KeychainStore

    init(_ key: String) {
        _store = StateObject(wrappedValue: KeychainStore(key: key))
    }

    var wrappedValue: String {
        get { store.value }
        nonmutating set { store.update(newValue) }
    }

    var projectedValue: Binding<String> {
        Binding(
            get: { store.value },
            set: { store.update($0) }
        )
    }
}

@MainActor
private final class KeychainStore: ObservableObject {
    let key: String
    @Published private(set) var value: String = ""
    private var observer: NSObjectProtocol?

    init(key: String) {
        self.key = key
        value = KeychainStorage.get(key) ?? ""
        observer = NotificationCenter.default.addObserver(
            forName: KeychainStorage.changeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Hop to the main actor explicitly — `notification.queue =
            // .main` posts dispatched onto the main runloop, but we
            // still need to enter MainActor before touching our state.
            guard let self else { return }
            let changedKey = note.userInfo?[KeychainStorage.changeNotificationKeyInfoKey] as? String
            guard changedKey == self.key else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let fresh = KeychainStorage.get(self.key) ?? ""
                if fresh != self.value { self.value = fresh }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func update(_ new: String) {
        guard new != value else { return }
        guard KeychainStorage.set(new, for: key) else { return }
        value = new
        // KeychainStorage.set posts changeNotification — sibling
        // KeychainStore instances will pick it up, but our own
        // observer will skip the update (value == fresh already).
    }
}
