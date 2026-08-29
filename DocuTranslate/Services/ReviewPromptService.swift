import Foundation
import StoreKit
import SwiftUI

@MainActor
final class ReviewPromptService: ObservableObject {
    static let shared = ReviewPromptService()

    @Published var showAlert = false

    private let requestedKey = "didRequestAppStoreReview"
    private var pendingSource: String?

    private init() {}

    /// Call after the user first signs, stamps, converts, translates, or exports a document.
    func considerPrompt(after source: String) {
        AppAnalytics.log("document_processed", ["source": source])
        guard !UserDefaults.standard.bool(forKey: requestedKey) else { return }
        UserDefaults.standard.set(true, forKey: requestedKey)
        pendingSource = source
        AppAnalytics.log("review_prompted", ["source": source])

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.showAlert = true
        }
    }

    func rateNow() {
        AppAnalytics.log("review_accepted", ["source": pendingSource ?? "unknown"])
        showAlert = false
        requestStoreReview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            PushNotificationService.shared.requestAuthorizationIfNeeded()
        }
    }

    func dismiss() {
        AppAnalytics.log("review_declined", ["source": pendingSource ?? "unknown"])
        showAlert = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            PushNotificationService.shared.requestAuthorizationIfNeeded()
        }
    }

    func requestStoreReview() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        SKStoreReviewController.requestReview(in: scene)
    }
}
