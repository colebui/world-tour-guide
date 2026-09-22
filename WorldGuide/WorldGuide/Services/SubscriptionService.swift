import Foundation
import Combine
import FirebaseAuth
import RevenueCat

/// Wraps RevenueCat. The subscription's source of truth for *gating content* is the server (the
/// metering function reads `users/{uid}.subscription`, written by the RevenueCat webhook); this
/// client mirror drives the paywall UI and instant unlock. RevenueCat's `appUserID` is set to the
/// Firebase uid via `logIn`, so an anonymous→linked account keeps one identity.
@MainActor
final class SubscriptionService: ObservableObject {
    @Published private(set) var isSubscribed = false
    @Published private(set) var packages: [Package] = []
    @Published var lastError: String?

    static let entitlementID = "plus"

    private var authHandle: AuthStateDidChangeListenerHandle?
    private var startedStream = false

    init() {
        // React to auth once both Firebase and RevenueCat are configured (configure() runs in the
        // App's init, before this listener can fire).
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.handleUser(user?.uid) }
        }
    }

    deinit {
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    private func handleUser(_ uid: String?) {
        guard Purchases.isConfigured, let uid else { return }
        if !startedStream {
            startedStream = true
            Task { @MainActor in
                for await info in Purchases.shared.customerInfoStream { apply(info) }
            }
        }
        Purchases.shared.logIn(uid) { [weak self] info, _, _ in
            Task { @MainActor in self?.apply(info) }
        }
        Task { await loadOfferings() }
    }

    func loadOfferings() async {
        guard Purchases.isConfigured else { return }
        do {
            let offerings = try await Purchases.shared.offerings()
            packages = offerings.current?.availablePackages ?? []
        } catch { lastError = error.localizedDescription }
    }

    func purchase(_ package: Package) async {
        guard Purchases.isConfigured else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Purchases.shared.purchase(package: package) { [weak self] _, info, error, userCancelled in
                Task { @MainActor in
                    if !userCancelled {
                        if let error { self?.lastError = error.localizedDescription }
                        else { self?.apply(info) }
                    }
                    cont.resume()
                }
            }
        }
    }

    func restore() async {
        guard Purchases.isConfigured else { return }
        do { apply(try await Purchases.shared.restorePurchases()) }
        catch { lastError = error.localizedDescription }
    }

    private func apply(_ info: CustomerInfo?) {
        isSubscribed = info?.entitlements[Self.entitlementID]?.isActive == true
    }
}
