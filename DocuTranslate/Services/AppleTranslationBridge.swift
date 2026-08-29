import SwiftUI

#if canImport(Translation)
import Translation
#endif

/// Hosts Apple's on-device Translation session (iOS 18+).
/// Attach `AppleTranslationHook()` in a visible view so language downloads can show system UI.
struct AppleTranslationHook: View {
    var body: some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            AppleTranslationHook18()
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct AppleTranslationHook18: View {
    @ObservedObject private var runtime = AppleTranslationRuntime.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(runtime.configuration) { session in
                await runtime.handle(session)
            }
    }
}

@available(iOS 18.0, *)
@MainActor
final class AppleTranslationRuntime: ObservableObject {
    static let shared = AppleTranslationRuntime()

    @Published var configuration: TranslationSession.Configuration?

    private var continuation: CheckedContinuation<String, Error>?
    private var pendingText: String?

    private init() {}

    func translate(
        _ text: String,
        from source: Language,
        to target: Language,
        detectSource: Bool
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation?.resume(throwing: CancellationError())
            self.continuation = continuation
            self.pendingText = text

            let sourceLanguage: Locale.Language? = detectSource
                ? nil
                : Locale.Language(identifier: source.translationCode)
            let config = TranslationSession.Configuration(
                source: sourceLanguage,
                target: Locale.Language(identifier: target.translationCode)
            )
            if configuration != nil {
                configuration?.invalidate()
            }
            configuration = config
        }
    }

    func handle(_ session: TranslationSession) async {
        guard let continuation, let text = pendingText else { return }
        self.continuation = nil
        pendingText = nil

        do {
            try await session.prepareTranslation()
            let chunks = TranslationService.splitIntoChunks(text, maxSize: 2500)
            var parts: [String] = []
            parts.reserveCapacity(chunks.count)
            for chunk in chunks {
                let response = try await session.translate(chunk)
                parts.append(response.targetText)
            }
            continuation.resume(returning: parts.joined(separator: "\n"))
        } catch {
            continuation.resume(throwing: error)
        }
    }
}
#endif
