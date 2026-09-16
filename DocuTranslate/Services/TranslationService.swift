import Foundation
import NaturalLanguage

#if canImport(Translation)
import Translation
#endif

// MARK: - Translation Service

@MainActor
class TranslationService: ObservableObject {
    @Published var isTranslating = false
    @Published var progress: Double = 0
    @Published var currentStep: TranslationStep = .uploading
    @Published var errorMessage: String?
    @Published var statusDetail: String = ""

    static let shared = TranslationService()
    private var skipOnDevice = false
    private init() {}

    // MARK: - Language Detection

    func detectLanguage(in text: String) -> Language? {
        let sample = String(text.prefix(2000))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return Language.find(by: dominant.rawValue)
    }

    // MARK: - Full Translation Pipeline

    func translate(
        text: String,
        from sourceLang: Language,
        to targetLang: Language,
        detectSource: Bool = false,
        progressHandler: @escaping (TranslationStep, Double) -> Void
    ) async throws -> String {
        let trimmed = decodeIfPercentEncoded(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { throw TranslationError.emptyText }

        if !detectSource, sourceLang.id == targetLang.id {
            return trimmed
        }

        let (masked, tokens) = TranslationMarkupGuard.protect(trimmed)
        let human = TranslationMarkupGuard.humanText(masked)
        if human.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return trimmed
        }

        statusDetail = "Starting translation…"
        report(.translating, 0.42, progressHandler)

        #if canImport(Translation)
        if #available(iOS 18.0, *), !skipOnDevice {
            do {
                let result = try await AppleTranslationRuntime.shared.translate(
                    masked,
                    from: sourceLang,
                    to: targetLang,
                    detectSource: detectSource
                )
                let restored = sanitizeTranslated(TranslationMarkupGuard.restore(result, tokens: tokens))
                if !isFailedTranslation(restored, original: trimmed) {
                    statusDetail = ""
                    report(.complete, 1.0, progressHandler)
                    return restored
                }
            } catch {
                // Timed out, simulator, language download, or unsupported pair — use online engines.
                skipOnDevice = true
                AppleTranslationRuntime.shared.failPending(CancellationError())
                statusDetail = "Using online translation…"
                report(.translating, 0.48, progressHandler)
            }
        }
        #endif

        let result = try await translateOnline(
            text: masked,
            from: sourceLang,
            to: targetLang,
            detectSource: detectSource,
            progressHandler: progressHandler
        )
        report(.complete, 1.0, progressHandler)
        return sanitizeTranslated(TranslationMarkupGuard.restore(result, tokens: tokens))
    }

    /// Translates each page on its own so multi-page documents keep one translated page per original page.
    func translatePages(
        _ pages: [String],
        from sourceLang: Language,
        to targetLang: Language,
        detectSource: Bool = false,
        progressHandler: @escaping (TranslationStep, Double) -> Void
    ) async throws -> [String] {
        guard !pages.isEmpty else { return [] }
        skipOnDevice = pages.count > 1
        defer {
            skipOnDevice = false
            statusDetail = ""
        }

        if pages.count == 1 {
            return [try await translate(
                text: pages[0],
                from: sourceLang,
                to: targetLang,
                detectSource: detectSource,
                progressHandler: progressHandler
            )]
        }

        report(.translating, 0.40, progressHandler)
        var results: [String] = []
        results.reserveCapacity(pages.count)
        var resolvedSource = sourceLang
        var didDetect = false
        let total = max(pages.count, 1)

        for (index, page) in pages.enumerated() {
            statusDetail = "Page \(index + 1) of \(total)"
            let fraction = 0.40 + 0.50 * Double(index) / Double(total)
            report(.translating, fraction, progressHandler)

            let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                results.append("")
                continue
            }

            let shouldDetect = detectSource && !didDetect
            let translated = try await translate(
                text: page,
                from: resolvedSource,
                to: targetLang,
                detectSource: shouldDetect,
                progressHandler: { _, _ in }
            )
            if shouldDetect {
                if let detected = detectLanguage(in: page) {
                    resolvedSource = detected
                }
                didDetect = true
            }
            results.append(translated)
            report(.translating, 0.40 + 0.50 * Double(index + 1) / Double(total), progressHandler)
        }

        statusDetail = ""
        report(.formatting, 0.90, progressHandler)
        return results
    }

    // MARK: - Online engines

    private func translateOnline(
        text: String,
        from sourceLang: Language,
        to targetLang: Language,
        detectSource: Bool,
        progressHandler: @escaping (TranslationStep, Double) -> Void
    ) async throws -> String {
        let sourceCode = detectSource ? "auto" : sourceLang.googleCode
        let targetCode = targetLang.googleCode
        let chunks = Self.splitIntoChunks(text, maxSize: 3500)
        var translatedChunks: [String] = []

        for (index, chunk) in chunks.enumerated() {
            statusDetail = chunks.count > 1 ? "Part \(index + 1) of \(chunks.count)" : ""
            let piece = try await translateChunk(chunk, from: sourceCode, to: targetCode)
            translatedChunks.append(piece)
            report(.translating, 0.40 + Double(index + 1) / Double(max(chunks.count, 1)) * 0.50, progressHandler)
        }

        statusDetail = ""
        report(.formatting, 0.90, progressHandler)
        let joined = translatedChunks.joined(separator: "\n")
        if isFailedTranslation(joined, original: text) {
            throw TranslationError.unsupportedLanguagePair
        }
        return joined
    }

    private func translateChunk(_ chunk: String, from source: String, to target: String) async throws -> String {
        do {
            let google = try await translateWithGoogle(chunk, from: source, to: target)
            if !isFailedTranslation(google, original: chunk) { return google }
        } catch {}

        if chunk.count <= 700 {
            do {
                let lingva = try await translateWithLingva(chunk, from: source, to: target)
                if !isFailedTranslation(lingva, original: chunk) { return lingva }
            } catch {}
        }

        let memory = try await translateWithMyMemory(chunk, from: source, to: target)
        if isFailedTranslation(memory, original: chunk) {
            throw TranslationError.unsupportedLanguagePair
        }
        return memory
    }

    // MARK: - Google Translate (no API key)

    private func translateWithGoogle(_ text: String, from source: String, to target: String) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "oe", value: "UTF-8"),
        ]
        guard let url = components.url else { throw TranslationError.networkUnavailable }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let encodedQuery = rfc3986Encode(text)
        if encodedQuery.count < 1800, let getURL = URL(string: url.absoluteString + "&q=\(encodedQuery)") {
            request.httpMethod = "GET"
            request.url = getURL
        } else {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = "q=\(encodedQuery)".data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TranslationError.networkUnavailable
        }
        return try parseGooglePayload(data)
    }

    private func parseGooglePayload(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [Any] else {
            throw TranslationError.networkUnavailable
        }

        var parts: [String] = []
        for sentence in sentences {
            guard let row = sentence as? [Any], let translated = row.first as? String else { continue }
            parts.append(translated)
        }
        let result = sanitizeTranslated(parts.joined())
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TranslationError.networkUnavailable
        }
        return result
    }

    // MARK: - Lingva

    private func translateWithLingva(_ text: String, from source: String, to target: String) async throws -> String {
        let pathText = rfc3986Encode(text)
        let endpoints = [
            "https://lingva.ml/api/v1/\(source)/\(target)/\(pathText)",
            "https://lingva.garudalinux.org/api/v1/\(source)/\(target)/\(pathText)",
        ]

        var lastError: Error = TranslationError.networkUnavailable
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let decoded = try JSONDecoder().decode(LingvaResponse.self, from: data)
                let result = sanitizeTranslated(decoded.translation)
                if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return result
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - MyMemory (last resort)

    private func translateWithMyMemory(_ text: String, from source: String, to target: String) async throws -> String {
        let chunks = Self.splitIntoChunks(text, maxSize: 400)
        var results: [String] = []
        let langpair = "\(source)|\(target)"

        for (index, chunk) in chunks.enumerated() {
            guard let url = URL(string: "https://api.mymemory.translated.net/get?q=\(rfc3986Encode(chunk))&langpair=\(rfc3986Encode(langpair))") else {
                throw TranslationError.networkUnavailable
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw TranslationError.networkUnavailable
            }

            let decoded = try JSONDecoder().decode(MyMemoryResponse.self, from: data)
            if decoded.responseStatus != nil, let status = decoded.responseStatus, status != 200 {
                throw TranslationError.quotaExceeded
            }
            let translated = sanitizeTranslated(decoded.responseData.translatedText)
            if isFailedTranslation(translated, original: chunk) {
                throw TranslationError.quotaExceeded
            }
            results.append(translated)

            if index < chunks.count - 1 {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        return results.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func report(
        _ step: TranslationStep,
        _ fraction: Double,
        _ progressHandler: (TranslationStep, Double) -> Void
    ) {
        currentStep = step
        progress = min(max(fraction, 0), 1)
        progressHandler(step, progress)
    }

    static func splitIntoChunks(_ text: String, maxSize: Int) -> [String] {
        guard text.count > maxSize else { return [text] }

        var chunks: [String] = []
        var current = ""

        let paragraphs = text.components(separatedBy: "\n")
        for paragraph in paragraphs {
            let piece = paragraph.isEmpty ? "\n" : paragraph + "\n"
            if current.count + piece.count > maxSize, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = piece
            } else {
                current += piece
            }
        }
        if !current.isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var final: [String] = []
        for chunk in chunks where !chunk.isEmpty {
            if chunk.count <= maxSize {
                final.append(chunk)
            } else {
                final.append(contentsOf: splitBySentences(chunk, maxSize: maxSize))
            }
        }
        return final.isEmpty ? [text] : final
    }

    private static func splitBySentences(_ text: String, maxSize: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            if current.count + sentence.count > maxSize, !current.isEmpty {
                pieces.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = sentence
            } else {
                current += sentence
            }
            return true
        }
        if !current.isEmpty {
            pieces.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var hard: [String] = []
        for piece in pieces {
            if piece.count <= maxSize {
                hard.append(piece)
            } else {
                var start = piece.startIndex
                while start < piece.endIndex {
                    let end = piece.index(start, offsetBy: maxSize, limitedBy: piece.endIndex) ?? piece.endIndex
                    hard.append(String(piece[start..<end]))
                    start = end
                }
            }
        }
        return hard
    }

    private func isFailedTranslation(_ result: String, original: String) -> Bool {
        let translated = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if translated.isEmpty { return true }
        if looksPercentEncoded(translated) { return true }

        let lowered = translated.lowercased()
        let failureMarkers = [
            "mymemory warning",
            "please select two distinct languages",
            "invalid language pair",
            "query length limit",
            "you used all available free translations",
            "quota",
            "error ",
        ]
        if failureMarkers.contains(where: { lowered.contains($0) }) {
            return true
        }

        let compactOriginal = original.filter { !$0.isWhitespace && !$0.isPunctuation }
        let compactTranslated = translated.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard compactOriginal.count > 50 else { return false }
        return compactOriginal.compare(compactTranslated, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// Matches JavaScript encodeURIComponent so spaces/newlines are not left as raw `%20` / `%0A` in the query.
    private func rfc3986Encode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func looksPercentEncoded(_ text: String) -> Bool {
        let pattern = "%(?:20|0A|0D|09|2C|27|22)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        let ns = text as NSString
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length)) >= 3
    }

    private func decodeIfPercentEncoded(_ text: String) -> String {
        looksPercentEncoded(text) ? decodePercentEncoding(text) : text
    }

    private func decodePercentEncoding(_ text: String) -> String {
        var current = text
        for _ in 0..<2 {
            if let decoded = current.removingPercentEncoding, decoded != current {
                current = decoded
            } else {
                break
            }
        }
        return current
            .replacingOccurrences(of: "%20", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "%0A", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "%0D\n", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "%0D", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "%09", with: "\t", options: .caseInsensitive)
    }

    private func sanitizeTranslated(_ text: String) -> String {
        decodeEntities(decodeIfPercentEncoded(text))
    }
}

// MARK: - Markup / code protection

/// Keeps XML, SVG, HTML tags, attributes, URLs, and hex colors untranslated
/// so source like `stroke="#c8aaff"` is not turned into Arabic (or any other language).
enum TranslationMarkupGuard {
    static func protect(_ text: String) -> (String, [String]) {
        var tokens: [String] = []
        var working = text
        if working.contains(DocumentPageBreak.marker) {
            tokens.append(DocumentPageBreak.marker)
            working = working.replacingOccurrences(of: DocumentPageBreak.marker, with: marker(tokens.count - 1))
        }
        working = replace(pattern: #"<!\[CDATA\[.*?\]\]>"#, in: working, tokens: &tokens, dotAll: true)
        working = replace(pattern: #"<[^>]+>"#, in: working, tokens: &tokens)
        working = replace(pattern: #"\b[\w:.-]+=(?:"[^"]*"|'[^']*')"#, in: working, tokens: &tokens)
        working = replace(pattern: #"https?://[^\s<>"]+"#, in: working, tokens: &tokens)
        working = replace(pattern: #"#[0-9A-Fa-f]{3,8}\b"#, in: working, tokens: &tokens)
        return (working, tokens)
    }

    static func humanText(_ masked: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{E000}\\d+\u{E001}") else { return masked }
        let ns = masked as NSString
        return regex.stringByReplacingMatches(
            in: masked,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: " "
        )
    }

    static func restore(_ translated: String, tokens: [String]) -> String {
        var result = translated
        for (index, token) in tokens.enumerated().reversed() {
            let mark = marker(index)
            if result.contains(mark) {
                result = result.replacingOccurrences(of: mark, with: token)
                continue
            }
            if let regex = try? NSRegularExpression(pattern: "\u{E000}\\s*\(index)\\s*\u{E001}") {
                let ns = result as NSString
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: NSRegularExpression.escapedTemplate(for: token)
                )
            }
        }
        return result
    }

    private static func marker(_ index: Int) -> String {
        "\u{E000}\(index)\u{E001}"
    }

    private static func replace(
        pattern: String,
        in text: String,
        tokens: inout [String],
        dotAll: Bool = false
    ) -> String {
        var options: NSRegularExpression.Options = []
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            guard range.location != NSNotFound, range.length > 0 else { continue }
            if range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            tokens.append(ns.substring(with: range))
            result += marker(tokens.count - 1)
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }
}

// MARK: - API models

private struct LingvaResponse: Decodable {
    let translation: String
}

private struct MyMemoryResponse: Decodable {
    let responseData: MyMemoryData
    let responseStatus: Int?
}

private struct MyMemoryData: Decodable {
    let translatedText: String
}

// MARK: - Errors

enum TranslationError: LocalizedError {
    case emptyText, invalidImage, unsupportedLanguagePair
    case networkUnavailable, quotaExceeded, documentTooLarge, extractionFailed

    var errorDescription: String? {
        switch self {
        case .emptyText:               return "The document appears to be empty."
        case .invalidImage:            return "Cannot process this image."
        case .unsupportedLanguagePair: return "Could not translate this language pair. Check the From/To languages and try again."
        case .networkUnavailable:      return "Translation needs an internet connection right now. Check your network and try again."
        case .quotaExceeded:           return "Translation limit reached. Try again in a few minutes."
        case .documentTooLarge:        return "Document too large. Split it into smaller parts."
        case .extractionFailed:        return "Could not extract text from this document."
        }
    }
}
