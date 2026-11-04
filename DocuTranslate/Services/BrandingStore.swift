import Foundation
import StoreKit
import SwiftUI

@MainActor
final class BrandingStore: ObservableObject {
    static let shared = BrandingStore()
    static let productID = "com.docutranslate.ios.remove_branding"

    nonisolated static let freeDocumentLimit = 3

    @Published private(set) var priceText = "$0.99"
    @Published private(set) var isLoading = false
    @Published private(set) var watermarkRevision = 0

    private let removedKey = "brandingRemovedDocumentIDs"
    nonisolated private static let completedKey = "editedSignedStampedDocumentIDs"
    private var product: Product?
    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = Task { await listenForTransactions() }
        Task { await loadProduct() }
    }

    nonisolated static func hasRemovedTag(for id: UUID) -> Bool {
        removedIDs().contains(id.uuidString)
    }

    /// Records an edited, signed, or stamped document. The first three stay free of the watermark.
    nonisolated static func recordCompletedDocument(_ id: UUID) {
        var ids = completedIDs()
        let key = id.uuidString
        guard !ids.contains(key) else { return }
        ids.append(key)
        UserDefaults.standard.set(ids, forKey: completedKey)
        Task { @MainActor in
            shared.watermarkRevision += 1
        }
    }

    /// Keeps the oldest edited, signed, or stamped documents as the three free files.
    nonisolated static func seedCompletedDocumentsIfNeeded(_ documents: [TranslatedDocument]) {
        guard UserDefaults.standard.object(forKey: completedKey) == nil else { return }
        var seen = Set<String>()
        var ids: [String] = []
        let acted = documents
            .filter { $0.wasEdited == true || $0.wasSigned == true }
            .sorted { $0.createdAt < $1.createdAt }
        for document in acted {
            let key = document.id.uuidString
            if seen.insert(key).inserted {
                ids.append(key)
            }
        }
        UserDefaults.standard.set(ids, forKey: completedKey)
    }

    nonisolated static func showsWatermarkWhileEditing(_ id: UUID) -> Bool {
        if hasRemovedTag(for: id) { return false }
        let ids = completedIDs()
        if let index = ids.firstIndex(of: id.uuidString) {
            return index >= freeDocumentLimit
        }
        return ids.count >= freeDocumentLimit
    }

    nonisolated static func showsPaywallWatermark(for document: TranslatedDocument) -> Bool {
        if document.brandingRemoved == true || hasRemovedTag(for: document.id) { return false }
        let acted = document.wasEdited == true || document.wasSigned == true
        guard acted else { return false }
        return showsWatermarkWhileEditing(document.id)
    }

    func showsWatermarkWhileEditing(_ id: UUID) -> Bool {
        _ = watermarkRevision
        return Self.showsWatermarkWhileEditing(id)
    }

    nonisolated private static func completedIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: completedKey) ?? []
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

                Text("Remove the watermark")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Pay \(store.priceText) for this document only. The watermark comes off this file. Signatures, stamps, and your edits stay.")
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
                        Text("Remove watermark — \(store.priceText)")
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
            Text("Watermark")
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
                        Text("Pay-per-document watermark")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.up")
                            .font(.caption)
                    }
                }
                .foregroundColor(.primary)
            } else {
                Text("Pay-per-document watermark")
                    .font(.subheadline.weight(.semibold))
            }
            Text("After three edited, signed, or stamped documents, the next one shows “Prepared by DocuTranslate” across the page. Pay \(store.priceText) to remove it from this document only.")
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
                    Text("Remove watermark — \(store.priceText)")
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

struct PaywallWatermarkBadge: View {
    var canvasSize: CGSize
    var onClose: () -> Void

    private var layout: DocumentWatermarkLayout {
        DocumentBranding.layout(for: canvasSize)
    }

    var body: some View {
        ZStack {
            Text(DocumentBranding.tag)
                .font(.system(size: layout.fontSize, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.2))
                .shadow(color: .white.opacity(0.85), radius: 0, x: 0, y: 1)
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(DocumentBranding.angleDegrees))
                .position(x: canvasSize.width / 2, y: canvasSize.height / 2)
                .allowsHitTesting(false)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.red)
                    .font(.system(size: max(20, layout.close.width * 0.72)))
                    .frame(width: layout.close.width, height: layout.close.height)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            }
            .buttonStyle(.plain)
            .position(x: layout.close.midX, y: layout.close.midY)
            .accessibilityLabel("Remove watermark")
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }
}
