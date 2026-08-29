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
    /// On-device translation can wait forever for a language download or a SwiftUI session that never starts.
    static let requestTimeout: TimeInterval = 12

    private init() {}

    func failPending(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        pendingText = nil
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func translate(
        _ text: String,
        from source: Language,
        to target: Language,
        detectSource: Bool
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await self.startSession(
                    text,
                    from: source,
                    to: target,
                    detectSource: detectSource
                )
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
                self.failPending(CancellationError())
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    private func startSession(
        _ text: String,
        from source: Language,
        to target: Language,
        detectSource: Bool
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            failPending(CancellationError())
            self.continuation = continuation
            self.pendingText = text

            let sourceLanguage: Locale.Language? = detectSource
                ? nil
                : Locale.Language(identifier: source.translationCode)
            configuration = TranslationSession.Configuration(
                source: sourceLanguage,
                target: Locale.Language(identifier: target.translationCode)
            )
        }
    }

    func handle(_ session: TranslationSession) async {
        guard let text = pendingText else { return }

        do {
            try await session.prepareTranslation()
            let chunks = TranslationService.splitIntoChunks(text, maxSize: 2500)
            var parts: [String] = []
            parts.reserveCapacity(chunks.count)
            for chunk in chunks {
                try Task.checkCancellation()
                let response = try await session.translate(chunk)
                parts.append(response.targetText)
            }
            finish(.success(parts.joined(separator: "\n")))
        } catch {
            finish(.failure(error))
        }
    }
}
#endif
