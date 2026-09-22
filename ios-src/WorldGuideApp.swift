import SwiftUI
import FirebaseCore
import FirebaseAppCheck
import RevenueCat

/// Picks the App Check attestation provider: App Attest on real devices, the debug provider in the
/// Simulator (which can't attest). The backend treats App Check in monitor mode for now, so a debug
/// token won't be rejected.
final class WGAppCheckFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if targetEnvironment(simulator)
        return AppCheckDebugProvider(app: app)
        #else
        return AppAttestProvider(app: app)
        #endif
    }
}

@main
struct WorldGuideApp: App {
    @StateObject private var auth = AuthService()
    @StateObject private var subs = SubscriptionService()

    init() {
        // Provider factory must be set BEFORE configure().
        AppCheck.setAppCheckProviderFactory(WGAppCheckFactory())
        FirebaseApp.configure()
        // Configure RevenueCat only once a real key is set, so the app stays usable until then.
        if Secrets.revenueCatAPIKey.hasPrefix("appl_") {
            Purchases.configure(withAPIKey: Secrets.revenueCatAPIKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environmentObject(auth)
                .environmentObject(subs)
                .task { await auth.bootstrap() }
        }
    }
}
