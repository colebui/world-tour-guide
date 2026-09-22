import SwiftUI
import RevenueCat

/// Shown when the backend reports the free limit is reached (HTTP 402). Presents the World Guide
/// Plus offering, purchase + Restore, the Apple-required auto-renew disclosure, and Terms/Privacy
/// links. Update `LegalLinks` once the documents are hosted.
enum LegalLinks {
    // TODO: replace with your hosted URLs before submitting to the App Store.
    static let terms = URL(string: "https://example.com/terms")!
    static let privacy = URL(string: "https://example.com/privacy")!
}

struct PaywallView: View {
    @EnvironmentObject var subs: SubscriptionService
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48)).foregroundStyle(.purple)
                    Text("World Guide Plus").font(.largeTitle.bold())
                    Text("You've used your free days. Subscribe for unlimited guides.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    benefits

                    if subs.packages.isEmpty {
                        ProgressView().padding()
                            .task { await subs.loadOfferings() }
                    } else {
                        ForEach(subs.packages, id: \.identifier) { package in
                            purchaseButton(package)
                        }
                    }

                    Button("Restore Purchases") {
                        Task { await subs.restore(); if subs.isSubscribed { dismiss() } }
                    }
                    .font(.subheadline)

                    disclosure

                    if let error = subs.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: subs.isSubscribed) { _, subscribed in
                if subscribed { dismiss() }
            }
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefit("infinity", "Unlimited tour guides, every day")
            benefit("waveform", "Premium AI narration")
            benefit("bookmark.fill", "Saved lists synced across devices")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical)
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.purple).frame(width: 28)
            Text(text)
            Spacer()
        }
    }

    private func purchaseButton(_ package: Package) -> some View {
        Button {
            Task {
                working = true
                await subs.purchase(package)
                working = false
                if subs.isSubscribed { dismiss() }
            }
        } label: {
            HStack {
                Text(package.storeProduct.localizedTitle.isEmpty ? "World Guide Plus" : package.storeProduct.localizedTitle)
                Spacer()
                if working { ProgressView() }
                else { Text("\(package.storeProduct.localizedPriceString) / mo").bold() }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.purple, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
        .disabled(working)
    }

    private var disclosure: some View {
        VStack(spacing: 8) {
            Text("Payment is charged to your Apple ID at confirmation. The subscription auto-renews monthly unless cancelled at least 24 hours before the period ends. Manage or cancel in iOS Settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Link("Terms", destination: LegalLinks.terms)
                Text("·").foregroundStyle(.secondary)
                Link("Privacy", destination: LegalLinks.privacy)
            }
            .font(.caption)
        }
    }
}
