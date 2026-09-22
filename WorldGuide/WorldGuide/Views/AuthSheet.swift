import SwiftUI
import AuthenticationServices

/// Optional account screen. Anonymous-first means this is never required — it lets a user upgrade
/// their silent anonymous account to Sign in with Apple or email so it (and their subscription)
/// follows them across devices. Reached from the account button in the bottom sheet.
struct AuthSheet: View {
    @EnvironmentObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var mode: Mode = .signIn
    @State private var showDeleteConfirm = false

    enum Mode { case signIn, signUp }

    var body: some View {
        NavigationStack {
            Form {
                usageSection

                if auth.isSignedIn {
                    signedInSection
                } else {
                    appleSection
                    emailSection
                }
                if let error = auth.lastError {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }

                deleteSection
            }
            .navigationTitle(auth.isSignedIn ? "Account" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete account and data", role: .destructive) {
                    Task { await auth.deleteAccount(); dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes your saved lists, usage history, and subscription record. This can't be undone.")
            }
        }
    }

    private var usageSection: some View {
        Section {
            if auth.isSubscribed {
                Label("World Guide Plus — unlimited guides", systemImage: "infinity")
                    .foregroundStyle(.purple)
            } else if let days = auth.freeDaysLeft {
                LabeledContent("Free days left") {
                    Text("\(days) of \(AuthService.freeActiveDays)")
                        .foregroundStyle(days == 0 ? .red : .primary)
                }
            }
        } footer: {
            if !auth.isSubscribed {
                Text("A day is used the first time you open a guide on a new date. Unused days don't count.")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Delete account", role: .destructive) { showDeleteConfirm = true }
                .disabled(auth.isWorking)
        } footer: {
            Text("Removes all your data from World Guide. You can keep using the app afterward as a new guest.")
        }
    }

    // MARK: - Signed in

    private var signedInSection: some View {
        Section {
            LabeledContent("Signed in as", value: auth.displayName)
            Button("Sign out", role: .destructive) {
                Task { await auth.signOut() }
            }
        } footer: {
            Text("Your saved places and subscription stay attached to this account across devices.")
        }
    }

    // MARK: - Apple

    private var appleSection: some View {
        Section {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
                request.nonce = auth.beginAppleSignIn()
            } onCompletion: { result in
                auth.completeAppleSignIn(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 46)
            .listRowInsets(EdgeInsets())
        } footer: {
            Text("Optional — keeps your places and subscription if you reinstall or switch devices.")
        }
    }

    // MARK: - Email

    private var emailSection: some View {
        Section("Or use email") {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(mode == .signUp ? .newPassword : .password)

            Picker("", selection: $mode) {
                Text("Sign in").tag(Mode.signIn)
                Text("Create account").tag(Mode.signUp)
            }
            .pickerStyle(.segmented)

            Button(mode == .signIn ? "Sign in" : "Create account") {
                Task {
                    switch mode {
                    case .signIn: await auth.signInWithEmail(email, password)
                    case .signUp: await auth.signUpWithEmail(email, password)
                    }
                    if auth.isSignedIn { dismiss() }
                }
            }
            .disabled(email.isEmpty || password.isEmpty || auth.isWorking)
        }
    }
}
