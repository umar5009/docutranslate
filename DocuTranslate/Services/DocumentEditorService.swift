import UIKit
import Vision

final class DocumentEditorService {
    static let shared = DocumentEditorService()
    private init() {}

    func detectTextBlocks(in image: UIImage) async -> [OCRTextBlock] {
        guard let cgImage = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let blocks = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation -> OCRTextBlock? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    let box = observation.boundingBox
                    let rect = CGRect(
                        x: box.origin.x,
                        y: 1 - box.origin.y - box.height,
                        width: box.width,
                        height: box.height
                    )
                    guard rect.height >= 0.008, rect.width >= 0.012 else { return nil }
                    return OCRTextBlock(text: text, rect: rect.clampedNormalized())
                }
                continuation.resume(returning: blocks)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.minimumTextHeight = 0.008
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    func detectFormFields(from blocks: [OCRTextBlock], page: Int) -> [DetectedFormField] {
        let labels = blocks
            .filter { isFieldLabel($0.text) }
            .sorted { lhs, rhs in
                abs(lhs.rect.minY - rhs.rect.minY) > 0.012
                    ? lhs.rect.minY < rhs.rect.minY
                    : lhs.rect.minX < rhs.rect.minX
            }
        var fields: [DetectedFormField] = []
        for label in labels {
            guard let kind = classifyField(label.text) else { continue }
            let occupied = fields.map(\.rect)
            var rect = fillRect(for: label, kind: kind, blocks: blocks, occupied: occupied)
            rect = clip(rect, avoiding: occupied)
            guard rect.width > 0.04, rect.height > 0.01 else { continue }
            if fields.contains(where: { $0.rect.intersects(rect.insetBy(dx: 0.003, dy: 0.002)) }) {
                continue
            }
            fields.append(
                DetectedFormField(
                    id: UUID(),
                    pageIndex: page,
                    kind: kind,
                    label: cleanedLabel(label.text),
                    rect: rect.clampedNormalized(),
                    labelRect: label.rect.clampedNormalized()
                )
            )
        }
        return fields
    }

    private func cleanedLabel(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " :.-"))
    }

    private func normalizedFieldText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func isFieldLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 42 else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count <= 7 else { return false }
        if isIgnoredLabel(trimmed) { return false }
        if trimmed.hasSuffix(":") || trimmed.hasSuffix("：") { return true }
        return classifyField(trimmed) != nil
    }

    private func isIgnoredLabel(_ text: String) -> Bool {
        containsAny(normalizedFieldText(text), [
            "conditions apply",
            "for bank use",
            "for branch use",
            "with stamp",
            "disclaimer"
        ])
    }

    func classifyField(_ text: String) -> FormFieldKind? {
        let lower = normalizedFieldText(text)
        if containsAny(lower, ["signature", "signatory", "signed by", "sign here", "customer signature", "bm signature", "authorized sign", "applicant sign"]) {
            return .signature
        }
        if isDateLabel(lower) {
            return .date
        }
        if lower == "yes" || lower == "no" || lower == "current" || lower == "savings"
            || (lower.hasPrefix("yes") && text.count <= 6) {
            return .checkbox
        }
        let strongText = [
            "name", "address", "cnic", "c/snic", "email", "mobile", "phone", "passport", "cif",
            "father", "mother", "occupation", "emp no", "employee", "branch code",
            "account type", "account no", "account number", "a/c no", "ntn", "iban"
        ]
        if containsAny(lower, strongText) {
            return .text
        }
        if lower.hasSuffix(" code") || lower == "code" || lower.hasSuffix(" number") {
            return .text
        }
        if text.trimmingCharacters(in: .whitespaces).hasSuffix(":") || text.trimmingCharacters(in: .whitespaces).hasSuffix("：") {
            return .text
        }
        return nil
    }

    private func isDateLabel(_ lower: String) -> Bool {
        let stripped = lower.trimmingCharacters(in: CharacterSet(charactersIn: " :.-"))
        if stripped == "date" || stripped == "dated" || stripped == "dob" || stripped == "d.o.b" {
            return true
        }
        if stripped.hasPrefix("date") && stripped.count <= 12 { return true }
        guard lower.count <= 24, !lower.contains("update") else { return false }
        return lower.range(of: #"\bdate\b"#, options: .regularExpression) != nil
            || lower.contains("d.o.b")
            || lower.contains("dob")
            || lower.contains("expiry")
            || (lower.contains("birth") && lower.count <= 18)
    }

    private func containsAny(_ text: String, _ keys: [String]) -> Bool {
        keys.contains { text.contains($0) }
    }

    private func fillStartX(for label: OCRTextBlock) -> CGFloat {
        let chars = CGFloat(max(2, label.text.trimmingCharacters(in: .whitespacesAndNewlines).count))
        let estimated = min(label.rect.width, max(label.rect.height * 1.6, chars * label.rect.height * 0.5))
        return min(label.rect.minX + estimated + 0.008, 0.94)
    }

    private func fillRect(for label: OCRTextBlock, kind: FormFieldKind, blocks: [OCRTextBlock], occupied: [CGRect]) -> CGRect {
        let box = label.rect
        if kind == .checkbox {
            let side = max(0.016, box.height * 1.15)
            return CGRect(x: max(0.02, box.minX - side * 1.35), y: box.midY - side / 2, width: side, height: side)
        }

        let startX = fillStartX(for: label)
        let sameLine = blocks.filter { block in
            abs(block.rect.midY - box.midY) < max(0.014, box.height * 0.9)
                && block.rect.minX > startX + 0.012
        }
        let nextBlockX = sameLine.map(\.rect.minX).min()
        let nextOccupiedX = occupied
            .filter { abs($0.midY - box.midY) < 0.02 && $0.minX > startX + 0.01 }
            .map(\.minX)
            .min()
        var nextX: CGFloat = 0.97
        if let value = nextBlockX { nextX = min(nextX, value) }
        if let value = nextOccupiedX { nextX = min(nextX, value) }

        var x = startX
        var width = nextX - startX - 0.01
        var height = max(0.016, box.height * 1.3)
        var y = box.minY - (height - box.height) * 0.2

        if kind == .date {
            height = max(height, 0.02)
            if width >= 0.07 {
                width = min(max(width, 0.1), 0.24)
            } else {
                width = min(0.22, max(0.14, box.width + 0.1))
                x = min(max(box.minX, 0.04), 0.97 - width)
                y = box.maxY + 0.004
                height = max(0.022, box.height * 1.4)
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        if kind == .signature {
            height = max(0.038, box.height * 2.2)
            if width < 0.18 {
                width = min(0.42, 0.92 - box.minX)
                y = box.maxY + 0.006
                x = box.minX
            } else {
                width = max(width, 0.22)
            }
        } else if width < 0.08 {
            width = min(0.55, 0.96 - box.minX)
            y = box.maxY + 0.004
            x = box.minX
            height = max(0.018, box.height * 1.15)
        }

        return CGRect(x: x, y: y, width: max(width, 0.08), height: height)
    }

    private func clip(_ rect: CGRect, avoiding occupied: [CGRect]) -> CGRect {
        var result = rect
        for other in occupied where result.intersects(other.insetBy(dx: 0.002, dy: 0.002)) {
            if other.minX > result.minX + 0.04 {
                result.size.width = max(0, other.minX - result.minX - 0.008)
            } else if other.maxX < result.maxX - 0.04 {
                let newX = other.maxX + 0.008
                result.size.width = max(0, result.maxX - newX)
                result.origin.x = newX
            }
        }
        return result
    }

    func render(pages: [UIImage], elements: [EditorElement]) -> [UIImage] {
        pages.enumerated().map { index, page in
            flatten(page: page, elements: elements.filter { $0.pageIndex == index })
        }
    }

    func flatten(page: UIImage, elements: [EditorElement]) -> UIImage {
        let size = page.size
        guard size.width > 1, size.height > 1 else { return page }
        let format = UIGraphicsImageRendererFormat()
        format.scale = page.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            page.draw(in: CGRect(origin: .zero, size: size))
            let sorted = elements.sorted { $0.zIndex < $1.zIndex }
            for element in sorted {
                draw(element, in: ctx.cgContext, pageSize: size, page: page)
            }
            drawConnectors(elements: elements, in: ctx.cgContext, pageSize: size)
        }
    }

    private func draw(_ element: EditorElement, in context: CGContext, pageSize: CGSize, page: UIImage) {
        context.saveGState()
        defer { context.restoreGState() }

        if element.kind == .ink {
            drawInk(element, in: context, pageSize: pageSize)
            return
        }

        let rect = element.rect.pixelRect(in: pageSize)
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: CGFloat(element.rotation * .pi / 180))
        context.translateBy(x: -rect.midX, y: -rect.midY)

        switch element.kind {
        case .existingText:
            guard element.isModified else { return }
            fillBackground(in: rect, page: page, pageSize: pageSize, context: context)
            drawText(element, in: rect, context: context)
        case .addedText:
            if element.sourceID != nil {
                drawCalloutBackground(element, in: rect, context: context)
            }
            drawText(element, in: rect, context: context)
        case .image:
            if let data = element.imageData, let image = UIImage(data: data) {
                image.draw(in: rect)
            }
        case .shape:
            drawShape(element, in: rect, pageSize: pageSize, context: context)
        case .link:
            drawLink(element, in: rect, context: context)
        case .redact:
            context.setFillColor(UIColor.black.cgColor)
            context.fill(rect)
        case .highlight:
            context.setFillColor(UIColor(editorHex: element.colorHex).withAlphaComponent(0.38).cgColor)
            context.fill(rect.insetBy(dx: 0, dy: -rect.height * 0.08))
        case .underline:
            context.setStrokeColor(UIColor(editorHex: element.colorHex).cgColor)
            context.setLineWidth(max(1.5, rect.height * 0.12))
            context.setLineCap(.round)
            let y = rect.maxY - max(1, rect.height * 0.08)
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.strokePath()
        case .strike:
            context.setStrokeColor(UIColor(editorHex: element.colorHex).cgColor)
            context.setLineWidth(max(1.5, rect.height * 0.12))
            context.setLineCap(.round)
            let y = rect.midY
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.strokePath()
        case .ink:
            break
        }
    }

    private func fillBackground(in rect: CGRect, page: UIImage, pageSize: CGSize, context: CGContext) {
        let padded = rect.insetBy(dx: -rect.width * 0.02, dy: -rect.height * 0.12)
        let color = sampleBackground(page: page, pageSize: pageSize, around: rect)
        context.setFillColor(color.cgColor)
        context.fill(padded)
    }

    private func sampleBackground(page: UIImage, pageSize: CGSize, around rect: CGRect) -> UIColor {
        let inset = rect.insetBy(dx: -4, dy: -4)
        let sample = CGPoint(x: max(0, inset.minX), y: max(0, inset.minY))
        guard let cg = page.cgImage else { return .white }
        let x = min(max(Int(sample.x * CGFloat(cg.width) / pageSize.width), 0), cg.width - 1)
        let y = min(max(Int(sample.y * CGFloat(cg.height) / pageSize.height), 0), cg.height - 1)
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return .white }
        let bytesPerPixel = max(cg.bitsPerPixel / 8, 1)
        let offset = y * cg.bytesPerRow + x * bytesPerPixel
        guard offset + 2 < CFDataGetLength(data) else { return .white }
        return UIColor(
            red: CGFloat(ptr[offset]) / 255,
            green: CGFloat(ptr[offset + 1]) / 255,
            blue: CGFloat(ptr[offset + 2]) / 255,
            alpha: 1
        )
    }

    private func drawText(_ element: EditorElement, in rect: CGRect, context: CGContext) {
        guard !element.text.isEmpty else { return }
        let size = max(8, element.fontSize * rect.height / max(element.rect.height, 0.001))
        let font = editorUIFont(name: element.fontName, size: size, bold: element.isBold, italic: element.isItalic)
        let color = UIColor(editorHex: element.colorHex)
        let style = NSMutableParagraphStyle()
        style.alignment = element.alignment == 1 ? .center : element.alignment == 2 ? .right : .left
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        if element.isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let textRect = rect.insetBy(dx: 2, dy: 1)
        (element.text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawShape(_ element: EditorElement, in rect: CGRect, pageSize: CGSize, context: CGContext) {
        let stroke = UIColor(editorHex: element.colorHex).cgColor
        let width = max(1.5, element.lineWidth * pageSize.width)
        context.setStrokeColor(stroke)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if let fill = element.fillHex {
            context.setFillColor(UIColor(editorHex: fill).withAlphaComponent(0.18).cgColor)
        }
        switch element.shapeKind {
        case .rectangle:
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
            if element.fillHex != nil { context.addPath(path.cgPath); context.fillPath() }
            context.addPath(path.cgPath)
            context.strokePath()
        case .ellipse:
            if element.fillHex != nil { context.fillEllipse(in: rect) }
            context.strokeEllipse(in: rect)
        case .line:
            context.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.strokePath()
        case .arrow:
            let start = CGPoint(x: rect.minX, y: rect.maxY)
            let end = CGPoint(x: rect.maxX, y: rect.minY)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head: CGFloat = max(10, min(rect.width, rect.height) * 0.22)
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
            context.strokePath()
        }
    }

    private func drawLink(_ element: EditorElement, in rect: CGRect, context: CGContext) {
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        let label = element.text.isEmpty ? element.url : element.text
        let font = UIFont.systemFont(ofSize: max(9, rect.height * 0.45), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        (label as NSString).draw(in: rect.insetBy(dx: 6, dy: 4), withAttributes: attributes)
    }

    private func drawInk(_ element: EditorElement, in context: CGContext, pageSize: CGSize) {
        guard element.points.count > 1 else { return }
        context.setStrokeColor(UIColor(editorHex: element.colorHex).withAlphaComponent(element.inkOpacity).cgColor)
        context.setLineWidth(max(1.5, element.inkWidth * pageSize.width))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setBlendMode(element.inkOpacity < 0.9 ? .multiply : .normal)
        let pixels = element.points.map { CGPoint(x: $0.x * pageSize.width, y: $0.y * pageSize.height) }
        context.move(to: pixels[0])
        for point in pixels.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    private func drawCalloutBackground(_ element: EditorElement, in rect: CGRect, context: CGContext) {
        let fill = UIColor(editorHex: element.fillHex ?? "#FFFBEB")
        let stroke = UIColor(editorHex: "#D97706")
        let path = UIBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -2), cornerRadius: 4)
        context.setFillColor(fill.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.setStrokeColor(stroke.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1.2)
        context.addPath(path.cgPath)
        context.strokePath()
    }

    private func drawConnectors(elements: [EditorElement], in context: CGContext, pageSize: CGSize) {
        let byID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
        for element in elements where element.kind == .addedText {
            guard let sourceID = element.sourceID, let source = byID[sourceID] else { continue }
            let connector = EditorConnector.between(
                source: source.rect.pixelRect(in: pageSize),
                target: element.rect.pixelRect(in: pageSize)
            )
            let color = UIColor(editorHex: "#EA580C")
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(max(1.6, pageSize.width * 0.0022))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: connector.start)
            context.addQuadCurve(to: connector.end, control: connector.control)
            context.strokePath()
            let head = connector.headPoints(length: max(8, pageSize.width * 0.012))
            context.move(to: connector.end)
            context.addLine(to: head.0)
            context.move(to: connector.end)
            context.addLine(to: head.1)
            context.strokePath()
        }
    }
}
