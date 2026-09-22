import Foundation
import Combine
import CryptoKit
import AuthenticationServices
import FirebaseAuth
import FirebaseFirestore

/// Owns the Firebase Auth session. The app is *anonymous-first*: on launch everyone gets a silent
/// anonymous account so every backend call is attributable (see the functions' requireUser). Users
/// can optionally upgrade to Sign in with Apple or email/password — linking preserves the same uid,
/// so their metering counters and subscription stay attached.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var freeDaysLeft: Int?   // nil while unknown or when subscribed (unlimited)
    @Published private(set) var isSubscribed = false
    @Published var lastError: String?
    @Published var isWorking = false

    /// Mirror of the backend's FREE_ACTIVE_DAYS metering constant, for display only.
    static let freeActiveDays = 5

    private var handle: AuthStateDidChangeListenerHandle?
    private var usageListener: ListenerRegistration?
    private var currentNonce: String?

    init() {
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.user = user
            self?.observeUsage(uid: user?.uid)
        }
    }

    deinit {
        if let handle { Auth.auth().removeStateDidChangeListener(handle) }
        usageListener?.remove()
    }

    /// Live view of the user's server-side usage doc: free days remaining + subscription state.
    private func observeUsage(uid: String?) {
        usageListener?.remove(); usageListener = nil
        guard let uid else { freeDaysLeft = nil; isSubscribed = false; return }
        usageListener = Firestore.firestore().collection("users").document(uid)
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    let data = snap?.data()
                    let used = (data?["usedDays"] as? [String])?.count ?? 0
                    let active = (data?["subscription"] as? [String: Any])?["active"] as? Bool ?? false
                    self?.isSubscribed = active
                    self?.freeDaysLeft = active ? nil : max(0, Self.freeActiveDays - used)
                }
            }
    }

    // MARK: - State

    var uid: String? { user?.uid }
    var isAnonymous: Bool { user?.isAnonymous ?? true }
    var isSignedIn: Bool { user != nil && !(user?.isAnonymous ?? true) }
    var displayName: String { isSignedIn ? (user?.email ?? "Signed in") : "Guest" }

    /// Ensures there's always a signed-in user (anonymous if needed). Call once on launch.
    func bootstrap() async {
        guard Auth.auth().currentUser == nil else { return }
        do { _ = try await Auth.auth().signInAnonymously() }
        catch { lastError = error.localizedDescription }
    }

    /// A fresh Firebase ID token for the Authorization header. Signs in anonymously first if needed.
    func idToken() async -> String? {
        if Auth.auth().currentUser == nil { await bootstrap() }
        return try? await Auth.auth().currentUser?.getIDToken()
    }

    // MARK: - Sign in with Apple (paired with SwiftUI's SignInWithAppleButton)

    /// Called from the button's `onRequest`: returns the SHA256 nonce to set on the request and
    /// stashes the raw nonce for verification in `completeAppleSignIn`.
    func beginAppleSignIn() -> String {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        return Self.sha256(nonce)
    }

    /// Called from the button's `onCompletion`: exchanges the Apple credential for a Firebase one.
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentNonce,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                lastError = "Apple sign-in failed."
                return
            }
            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idToken, rawNonce: nonce, fullName: credential.fullName)
            Task { await linkOrSignIn(with: firebaseCredential) }
        }
    }

    // MARK: - Email/password

    func signUpWithEmail(_ email: String, _ password: String) async {
        await linkOrSignIn(with: EmailAuthProvider.credential(withEmail: email, password: password))
    }

    func signInWithEmail(_ email: String, _ password: String) async {
        isWorking = true; defer { isWorking = false }
        do { _ = try await Auth.auth().signIn(withEmail: email, password: password) }
        catch { lastError = error.localizedDescription }
    }

    // MARK: - Sign out / delete

    func signOut() async {
        do {
            try Auth.auth().signOut()
            await bootstrap()   // drop back to a fresh anonymous session
        } catch { lastError = error.localizedDescription }
    }

    /// Deletes the account end-to-end: wipes server-side data (lists + metering/subscription doc),
    /// then the Firebase Auth account, then starts a fresh anonymous session. Satisfies Apple's
    /// in-app account-deletion requirement.
    func deleteAccount() async {
        isWorking = true; defer { isWorking = false }
        guard let user = Auth.auth().currentUser, let token = try? await user.getIDToken() else { return }

        // 1. Server-side wipe via the deleteUserData function (same host as backendURL,
        //    which ends in the function name "getPlaceContent").
        let deleteURL = Secrets.backendURL.replacingOccurrences(of: "getPlaceContent", with: "deleteUserData")
        if let url = URL(string: deleteURL) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }

        // 2. Delete the Auth account, then drop back to a fresh anonymous session.
        do {
            try await user.delete()
            await bootstrap()
        } catch { lastError = error.localizedDescription }
    }

    // MARK: - Helpers

    /// Links a credential to the current anonymous user (keeping the uid); if that credential already
    /// belongs to an account, signs into it instead.
    private func linkOrSignIn(with credential: AuthCredential) async {
        isWorking = true; defer { isWorking = false }
        if let current = Auth.auth().currentUser, current.isAnonymous {
            do { _ = try await current.link(with: credential); return }
            catch { /* credential already in use, or password mismatch → try a plain sign-in */ }
        }
        do { _ = try await Auth.auth().signIn(with: credential) }
        catch { lastError = error.localizedDescription }
    }

    private static func randomNonceString(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms) == errSecSuccess else {
                fatalError("Unable to generate nonce")
            }
            for random in randoms where remaining > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
