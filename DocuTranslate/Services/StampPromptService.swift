import Foundation
import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

struct StampGenerationResult {
    var blueprint: StampBlueprint
    var image: UIImage
    var reply: String
}

class StampPromptService {
    static let shared = StampPromptService()
    private init() {}

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy"
        return formatter
    }()

    func generate(from prompt: String, previous: StampBlueprint?) async -> StampGenerationResult {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var spec = previous ?? StampBlueprint()

        if #available(iOS 26.0, *) {
            if let ai = await interpretWithAppleIntelligence(trimmed, previous: spec) {
                spec = ai
            } else {
                spec = interpretLocally(trimmed, previous: spec)
            }
        } else {
            spec = interpretLocally(trimmed, previous: spec)
        }

        if spec.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spec.title = previous?.title.isEmpty == false ? previous!.title : "COMPANY NAME"
        }
        if spec.dateText.isEmpty == false || trimmed.localizedCaseInsensitiveContains("date") {
            if spec.dateText.isEmpty {
                spec.dateText = dateFormatter.string(from: Date()).uppercased()
            }
        }

        let image = SignStampService.shared.makeStamp(from: spec)
        return StampGenerationResult(blueprint: spec, image: image, reply: reply(for: spec, prompt: trimmed))
    }

    // MARK: - Local prompt understanding

    func interpretLocally(_ prompt: String, previous: StampBlueprint) -> StampBlueprint {
        var spec = previous
        let lower = prompt.lowercased()

        if let color = detectedColor(in: lower) {
            spec.colorName = color
        }

        if lower.contains("circle") || lower.contains("round") || lower.contains("oval") || lower.contains("seal") {
            spec.shape = .oval
            spec.isSeal = true
        } else if lower.contains("rectangle") || lower.contains("square") || lower.contains("box") {
            spec.shape = .roundedRect
            spec.isSeal = false
        }

        if lower.contains("company") || lower.contains("seal") || lower.contains("letterhead") {
            spec.isSeal = true
            spec.shape = .oval
        }

        if lower.contains("date") || lower.contains("today") {
            spec.dateText = dateFormatter.string(from: Date()).uppercased()
        } else if lower.contains("no date") || lower.contains("without date") {
            spec.dateText = ""
        }

        if let company = extractValue(from: prompt, labels: ["company name", "company", "named", "called", "name"]) {
            spec.title = company
            spec.isSeal = true
            spec.shape = .oval
        } else if let quoted = extractQuoted(from: prompt) {
            spec.title = quoted
        } else if let preset = StampStyle.presets.first(where: { lower.contains($0.0.lowercased()) }) {
            spec.title = preset.0
            spec.colorName = colorName(for: preset.1.color) ?? spec.colorName
            spec.shape = preset.1.shape
            spec.isSeal = preset.1.shape == .oval
        } else if let leftover = leftoverTitle(from: prompt), leftover.count >= 3,
                  !["it", "this", "that", "please", "stamp"].contains(leftover.lowercased()) {
            spec.title = leftover
        }

        if let subtitle = extractValue(from: prompt, labels: ["subtitle", "department", "tagline"]) {
            spec.subtitle = subtitle
        }
        if let footer = extractValue(from: prompt, labels: ["footer", "city", "location"]) {
            spec.footer = footer
        }

        if spec.isSeal && spec.title.isEmpty {
            spec.title = "COMPANY NAME"
        }

        return spec
    }

    private func detectedColor(in lower: String) -> String? {
        let colors = ["red", "green", "blue", "purple", "orange", "teal", "gray", "grey", "black"]
        guard let match = colors.first(where: { lower.contains($0) }) else { return nil }
        if match == "grey" || match == "black" { return "Gray" }
        return match.capitalized
    }

    private func colorName(for color: UIColor) -> String? {
        StampStyle.inkChoices.first(where: { lhs, rhs in
            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            rhs.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return abs(r1 - r2) < 0.04 && abs(g1 - g2) < 0.04 && abs(b1 - b2) < 0.04
        })?.0
    }

    private func extractQuoted(from prompt: String) -> String? {
        let pattern = "\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(prompt.startIndex..., in: prompt)
        guard let match = regex.firstMatch(in: prompt, range: range),
              let swiftRange = Range(match.range(at: 1), in: prompt) else { return nil }
        return String(prompt[swiftRange]).trimmingCharacters(in: .whitespaces)
    }

    private func extractValue(from prompt: String, labels: [String]) -> String? {
        let lowered = prompt
        for label in labels {
            guard let regex = try? NSRegularExpression(
                pattern: "(?i)\(NSRegularExpression.escapedPattern(for: label))\\s*(?:is|:)?\\s*([A-Za-z0-9&.\\-' ]+?)(?=\\s+(?:and|with|in|on|using|color|colour|date|today|red|blue|green|purple|orange|teal|gray|grey|black|circle|round|oval|seal|rectangle)\\b|$)",
                options: []
            ) else { continue }
            let range = NSRange(lowered.startIndex..., in: lowered)
            if let match = regex.firstMatch(in: lowered, range: range),
               let swiftRange = Range(match.range(at: 1), in: lowered) {
                let value = String(lowered[swiftRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
                if value.count >= 2, !["and", "with", "the", "a"].contains(value.lowercased()) {
                    return value
                }
            }
        }
        return nil
    }

    private func leftoverTitle(from prompt: String) -> String? {
        var text = prompt
        let junk = [
            "create", "make", "generate", "stamp", "a stamp", "with", "please",
            "color", "colour", "today", "current", "using", "add", "include",
            "circular", "circle", "round", "oval", "seal", "rectangle", "date",
            "company name", "company", "and", "the", "a", "an"
        ]
        for word in junk {
            text = text.replacingOccurrences(of: word, with: " ", options: [.caseInsensitive])
        }
        for (name, _) in StampStyle.inkChoices {
            text = text.replacingOccurrences(of: name, with: " ", options: [.caseInsensitive])
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 2 ? text : nil
    }

    private func reply(for spec: StampBlueprint, prompt: String) -> String {
        var parts: [String] = ["Created a \(spec.colorName.lowercased())"]
        parts.append(spec.isSeal ? "company seal" : "stamp")
        parts.append("for \(spec.displayName)")
        if !spec.dateText.isEmpty {
            parts.append("dated \(spec.dateText)")
        }
        var text = parts.joined(separator: " ") + "."
        if spec.title.uppercased() == "COMPANY NAME" && !prompt.lowercased().contains("acme") {
            text += " Tell me the company name or a color to refine it."
        } else {
            text += " You can say “make it blue” or “add today’s date” to adjust it."
        }
        return text
    }

    // MARK: - Apple Intelligence (iOS 26+)

    @available(iOS 26.0, *)
    private func interpretWithAppleIntelligence(_ prompt: String, previous: StampBlueprint) async -> StampBlueprint? {
        #if canImport(FoundationModels)
        do {
            let session = LanguageModelSession(instructions: """
            You design official document stamps. Return ONLY compact JSON with keys:
            title, subtitle, includeDate (bool), color (Red|Green|Blue|Purple|Orange|Teal|Gray),
            shape (roundedRect|oval), isSeal (bool), footer.
            Use previous values when the user only changes one detail.
            Previous JSON: \(previousJSON(previous))
            """)
            let response = try await session.respond(to: prompt)
            let content = String(describing: response)
            return parseAIJSON(content, previous: previous)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func previousJSON(_ spec: StampBlueprint) -> String {
        """
        {"title":"\(spec.title)","subtitle":"\(spec.subtitle)","includeDate":\(spec.dateText.isEmpty ? "false" : "true"),"color":"\(spec.colorName)","shape":"\(spec.shape == .oval ? "oval" : "roundedRect")","isSeal":\(spec.isSeal ? "true" : "false"),"footer":"\(spec.footer)"}
        """
    }

    private func parseAIJSON(_ raw: String, previous: StampBlueprint) -> StampBlueprint? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var spec = previous
        if let title = object["title"] as? String, !title.isEmpty { spec.title = title }
        if let subtitle = object["subtitle"] as? String { spec.subtitle = subtitle }
        if let footer = object["footer"] as? String { spec.footer = footer }
        if let color = object["color"] as? String, !color.isEmpty { spec.colorName = color.capitalized }
        if let shape = object["shape"] as? String {
            spec.shape = shape.lowercased().contains("oval") || shape.lowercased().contains("seal") ? .oval : .roundedRect
        }
        if let seal = object["isSeal"] as? Bool { spec.isSeal = seal }
        if let includeDate = object["includeDate"] as? Bool {
            spec.dateText = includeDate ? dateFormatter.string(from: Date()).uppercased() : spec.dateText
        }
        return spec
    }
}
