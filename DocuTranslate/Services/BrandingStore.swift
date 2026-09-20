import Foundation
import StoreKit
import SwiftUI

@MainActor
final class BrandingStore: ObservableObject {
    static let shared = BrandingStore()
    static let productID = "com.docutranslate.ios.remove_branding"

    @Published private(set) var priceText = "$0.99"
    @Published private(set) var isLoading = false

    private let removedKey = "brandingRemovedDocumentIDs"
    private var product: Product?
    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = Task { await listenForTransactions() }
        Task { await loadProduct() }
    }

    nonisolated static func hasRemovedTag(for id: UUID) -> Bool {
        removedIDs().contains(id.uuidString)
    }

    nonisolated private static func removedIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "brandingRemovedDocumentIDs") ?? [])
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            if let match = products.first {
                product = match
                priceText = match.displayPrice
            }
        } catch {
            priceText = "$0.99"
        }
    }

    func logPurchaseButtonClick(source: String) {
        logPay("branding_buy", source: source)
    }

    func purchaseRemoval(for documentID: UUID, source: String = "unknown") async throws {
        isLoading = true
        defer { isLoading = false }

        if product == nil {
            await loadProduct()
        }
        guard let product else {
            logPay("pay_product_unavailable", source: source)
            throw BrandingPurchaseError.productUnavailable
        }

        logPay("pay_purchase_started", source: source)
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification, source: source)
            markRemoved(documentID)
            await transaction.finish()
            logPay("branding_removed", source: source)
            logPay("pay_purchase_success", source: source)
        case .userCancelled:
            logPay("pay_purchase_discarded", source: source)
            throw BrandingPurchaseError.cancelled
        case .pending:
            logPay("pay_purchase_pending", source: source)
            throw BrandingPurchaseError.pending
        @unknown default:
            logPay("pay_purchase_failed", source: source, extra: ["reason": "unknown"])
            throw BrandingPurchaseError.failed
        }
    }

    private func logPay(_ name: String, source: String, extra: [String: Any] = [:]) {
        var params: [String: Any] = [
            "product": Self.productID,
            "price": priceText,
            "source": source
        ]
        extra.forEach { params[$0.key] = $0.value }
        if name == "branding_buy" {
            AppAnalytics.tap(name, params)
        } else {
            AppAnalytics.log(name, params)
        }
    }

    private func markRemoved(_ id: UUID) {
        var ids = Self.removedIDs()
        ids.insert(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: removedKey)
        objectWillChange.send()
    }

    private func checkVerified<T>(_ result: VerificationResult<T>, source: String = "unknown") throws -> T {
        switch result {
        case .unverified:
            logPay("pay_purchase_failed", source: source, extra: ["reason": "unverified"])
            throw BrandingPurchaseError.failed
        case .verified(let value):
            return value
        }
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if let transaction = try? checkVerified(result) {
                await transaction.finish()
            }
        }
    }
}

enum BrandingPurchaseError: LocalizedError {
    case productUnavailable, cancelled, pending, failed

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "The $0.99 tag removal product is not available yet. Add com.docutranslate.ios.remove_branding as a consumable In-App Purchase in App Store Connect."
        case .cancelled:
            return nil
        case .pending:
            return "The purchase is pending approval."
        case .failed:
            return "The purchase could not be completed. Try again."
        }
    }
}

enum LegalURLs {
    static let privacy = URL(string: "https://github.com/umar5009/docutranslate-privacy-support-page/blob/main/PRIVACY.md")!
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

struct PurchaseLegalLinks: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("By purchasing, you agree to the Terms of Use (EULA) and Privacy Policy.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Link("Privacy Policy", destination: LegalURLs.privacy)
                    .simultaneousGesture(TapGesture().onEnded {
                        AppAnalytics.tap("purchase_privacy")
                    })
                Text("·")
                    .foregroundColor(.secondary)
                Link("Terms of Use (EULA)", destination: LegalURLs.termsOfUse)
                    .simultaneousGesture(TapGesture().onEnded {
                        AppAnalytics.tap("purchase_eula")
                    })
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }
}

struct RemoveTagPaymentSheet: View {
    let documentID: UUID
    var onPurchased: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BrandingStore.shared
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "tag.slash.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)

                Text("Remove “\(DocumentBranding.tag)”")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Pay \(store.priceText) to remove this tag from this document only. Signatures, stamps, and dates stay on the page.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    store.logPurchaseButtonClick(source: "sheet")
                    Task { await buy() }
                } label: {
                    HStack {
                        if store.isLoading {
                            ProgressView().tint(.white)
                        }
                        Text("Remove tag — \(store.priceText)")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(store.isLoading)

                PurchaseLegalLinks()

                Spacer()
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: AppAnalytics.action("branding_cancel") { dismiss() })
                }
            }
            .alert("Purchase", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel, action: AppAnalytics.action("branding_error_ok") {})
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            AppAnalytics.log("pay_sheet_shown", [
                "product": BrandingStore.productID,
                "price": store.priceText,
                "source": "sheet"
            ])
        }
    }

    private func buy() async {
        do {
            try await store.purchaseRemoval(for: documentID, source: "sheet")
            onPurchased()
            dismiss()
        } catch BrandingPurchaseError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RemoveBrandingBanner: View {
    @Binding var document: TranslatedDocument
    var compact: Bool = false
    var onRemoved: ((TranslatedDocument) -> Void)? = nil

    @ObservedObject private var store = BrandingStore.shared
    @State private var errorMessage: String?
    @State private var expanded = false

    var body: some View {
        if document.showsBrandingTag {
            if compact && !expanded {
                compactBanner
            } else {
                fullBanner
            }
        }
    }

    private var compactBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.fill")
                .font(.caption)
            Text("Tagged")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Remove \(store.priceText)") {
                store.logPurchaseButtonClick(source: "banner")
                Task { await buy() }
            }
            .font(.caption.weight(.semibold))
            Button {
                AppAnalytics.tap("branding_info_expand")
                withAnimation { expanded = true }
            } label: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(10)
        .alert("Purchase", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel, action: AppAnalytics.action("branding_error_ok") {})
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var fullBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact {
                Button {
                    AppAnalytics.tap("branding_info_collapse")
                    withAnimation { expanded = false }
                } label: {
                    HStack {
                        Text("Tagged “\(DocumentBranding.tag)”")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.up")
                            .font(.caption)
                    }
                }
                .foregroundColor(.primary)
            } else {
                Text("Tagged “\(DocumentBranding.tag)”")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Converted, signed, and scanned files include this small footer. Pay \(store.priceText) to remove it from this document only.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                store.logPurchaseButtonClick(source: "banner")
                Task { await buy() }
            } label: {
                HStack {
                    if store.isLoading {
                        ProgressView().tint(.white)
                    }
                    Text("Remove tag — \(store.priceText)")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(store.isLoading)

            PurchaseLegalLinks()
        }
        .padding()
        .background(Color.orange.opacity(0.12))
        .cornerRadius(14)
        .alert("Purchase", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel, action: AppAnalytics.action("branding_error_ok") {})
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func buy() async {
        do {
            try await store.purchaseRemoval(for: document.id, source: "banner")
            document.brandingRemoved = true
            onRemoved?(document)
        } catch BrandingPurchaseError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
