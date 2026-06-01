import SwiftUI

@main
struct VektorPadApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Match the macOS app's first-launch default: 2 decimal places,
        // currency- and pilot-friendly. No-op once a value exists.
        if UserDefaults.standard.object(forKey: "vektor.precision") == nil {
            UserDefaults.standard.set(2, forKey: "vektor.precision")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}
