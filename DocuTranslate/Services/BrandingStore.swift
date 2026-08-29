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

    func purchaseRemoval(for documentID: UUID) async throws {
        isLoading = true
        defer { isLoading = false }

        if product == nil {
            await loadProduct()
        }
        guard let product else {
            throw BrandingPurchaseError.productUnavailable
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            markRemoved(documentID)
            await transaction.finish()
            AppAnalytics.log("branding_removed", ["product": Self.productID])
        case .userCancelled:
            throw BrandingPurchaseError.cancelled
        case .pending:
            throw BrandingPurchaseError.pending
        @unknown default:
            throw BrandingPurchaseError.failed
        }
    }

    private func markRemoved(_ id: UUID) {
        var ids = Self.removedIDs()
        ids.insert(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: removedKey)
        objectWillChange.send()
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
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

struct RemoveTagPaymentSheet: View {
    let documentID: UUID
    var onPurchased: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BrandingStore.shared
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
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
                    AppAnalytics.tap("branding_buy")
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
    }

    private func buy() async {
        do {
            try await store.purchaseRemoval(for: documentID)
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
    var onRemoved: ((TranslatedDocument) -> Void)? = nil

    @ObservedObject private var store = BrandingStore.shared
    @State private var errorMessage: String?

    var body: some View {
        if document.showsBrandingTag {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tagged “\(DocumentBranding.tag)”")
                    .font(.subheadline.weight(.semibold))
                Text("Converted, signed, and scanned files include this small footer. Pay \(store.priceText) to remove it from this document only.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    AppAnalytics.tap("branding_buy")
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
    }

    private func buy() async {
        do {
            try await store.purchaseRemoval(for: document.id)
            document.brandingRemoved = true
            onRemoved?(document)
        } catch BrandingPurchaseError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
