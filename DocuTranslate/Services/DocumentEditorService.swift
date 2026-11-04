import UIKit
import Vision

final class DocumentEditorService {
    static let shared = DocumentEditorService()
    private init() {}

    func detectTextBlocks(in image: UIImage) async -> [OCRTextBlock] {
        guard let cgImage = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: FontStyleReader.blocks(from: observations, image: image))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.minimumTextHeight = 0.008
            if #available(iOS 16.0, *) {
                request.revision = VNRecognizeTextRequest.currentRevision
            }
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
                draw(element, in: ctx.cgContext, pageSize: size, page: page, peers: sorted)
            }
            drawConnectors(elements: elements, in: ctx.cgContext, pageSize: size)
        }
    }

    private func draw(_ element: EditorElement, in context: CGContext, pageSize: CGSize, page: UIImage, peers: [EditorElement]) {
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
            fillBackground(in: rect, page: page, pageSize: pageSize, context: context, paperHex: element.fillHex)
            guard !element.text.isEmpty else { return }
            let group = printedReplacementGroup(for: element, in: peers)
            let union = group.reduce(element.rect) { $0.union($1.rect) }
            let unionRect = union.pixelRect(in: pageSize)
            if unionRect.width > rect.width + 1 || unionRect.height > rect.height + 1 {
                fillBackground(in: unionRect, page: page, pageSize: pageSize, context: context, paperHex: element.fillHex)
            }
            drawWrappedReplacement(element, in: unionRect, pageSize: pageSize)
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

    func paperHex(in image: UIImage, around normalized: CGRect) -> String {
        guard let cg = image.cgImage else { return "#FFFFFF" }
        let pixelSize = CGSize(width: cg.width, height: cg.height)
        let rect = normalized.pixelRect(in: pixelSize)
        let points = [
            CGPoint(x: rect.midX, y: rect.minY - 5),
            CGPoint(x: rect.minX - 5, y: rect.midY),
            CGPoint(x: rect.maxX + 5, y: rect.midY),
            CGPoint(x: rect.minX - 4, y: rect.minY - 4),
            CGPoint(x: rect.maxX + 4, y: rect.minY - 4)
        ]
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return "#FFFFFF" }
        let bytesPerPixel = max(cg.bitsPerPixel / 8, 1)
        var bestLuma = -1
        var red = 255, green = 255, blue = 255
        for point in points {
            let x = min(max(Int(point.x), 0), cg.width - 1)
            let y = min(max(Int(point.y), 0), cg.height - 1)
            let offset = y * cg.bytesPerRow + x * bytesPerPixel
            guard offset + 2 < CFDataGetLength(data) else { continue }
            let r = Int(ptr[offset])
            let g = Int(ptr[offset + 1])
            let b = Int(ptr[offset + 2])
            let luma = r + g + b
            if luma > bestLuma {
                bestLuma = luma
                red = r
                green = g
                blue = b
            }
        }
        if bestLuma < 180 { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private func fillBackground(in rect: CGRect, page: UIImage, pageSize: CGSize, context: CGContext, paperHex: String?) {
        let padX = min(3, max(1, rect.height * 0.1))
        let padY = min(1.5, max(0.5, rect.height * 0.06))
        let padded = rect.insetBy(dx: -padX, dy: -padY)
        let color = paperHex.map { UIColor(editorHex: $0) } ?? sampleBackground(page: page, pageSize: pageSize, around: rect)
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

    private func printedReplacementGroup(for element: EditorElement, in peers: [EditorElement]) -> [EditorElement] {
        let printed = peers.filter { $0.pageIndex == element.pageIndex && $0.kind == .existingText }
        let heights = printed.map(\.rect.height).filter { $0 > 0.004 }.sorted()
        let pitch = heights.isEmpty ? CGFloat(0.015) : max(heights[min(heights.count - 1, heights.count * 3 / 10)], 0.008)
        let words = peers.filter {
            $0.pageIndex == element.pageIndex && $0.kind == .existingText && $0.isModified
        }.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > pitch * 0.65 {
                return lhs.rect.minY < rhs.rect.minY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
        var groups: [[EditorElement]] = []
        for word in words {
            if word.text.isEmpty, let last = groups.last?.last, word.rect.minY - last.rect.maxY < pitch * 1.25 {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups.first { $0.contains { $0.id == element.id } } ?? [element]
    }

    private func drawWrappedReplacement(_ element: EditorElement, in rect: CGRect, pageSize: CGSize) {
        guard !element.text.isEmpty else { return }
        let size = max(6, element.fontSize * pageSize.height)
        let font = editorUIFont(name: element.fontName, size: size, bold: element.isBold, italic: element.isItalic)
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(editorHex: element.colorHex),
            .paragraphStyle: style
        ]
        if element.isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let measured = (element.text as NSString).boundingRect(
            with: CGSize(width: max(rect.width, 8), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let drawRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(rect.width, 8),
            height: max(rect.height, ceil(measured.height) + 2)
        )
        (element.text as NSString).draw(in: drawRect, withAttributes: attributes)
    }

    private func drawText(_ element: EditorElement, in rect: CGRect, context: CGContext) {
        guard !element.text.isEmpty else { return }
        let size = max(8, element.fontSize * rect.height / max(element.rect.height, 0.001))
        let textRect = rect.insetBy(dx: 1, dy: 0)
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
        let lineHeight = font.lineHeight
        let origin = CGPoint(x: textRect.minX, y: rect.midY - lineHeight / 2)
        (element.text as NSString).draw(at: origin, withAttributes: attributes)
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

/// Reads per-character boxes from Vision, then estimates size, weight, slant, family, and color from the ink.
private enum FontStyleReader {
    static func blocks(from observations: [VNRecognizedTextObservation], image: UIImage) -> [OCRTextBlock] {
        let raster = PageRaster(image: image)
        return observations.prefix(200).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let lineRect = CGRect(
                x: box.origin.x,
                y: 1 - box.origin.y - box.height,
                width: box.width,
                height: box.height
            ).clampedNormalized()
            guard lineRect.height >= 0.008, lineRect.width >= 0.012 else { return nil }
            let glyphs = measureGlyphs(in: candidate, raster: raster)
            let runs = wordRuns(from: glyphs, fallback: lineRect, raster: raster)
            guard let dominant = runs.max(by: { $0.text.count < $1.text.count }) else { return nil }
            return OCRTextBlock(
                text: candidate.string,
                rect: lineRect,
                fontSize: dominant.fontSize,
                fontName: dominant.fontName,
                isBold: dominant.isBold,
                isItalic: dominant.isItalic,
                isUnderline: dominant.isUnderline,
                colorHex: dominant.colorHex,
                runs: runs
            )
        }
    }

    private struct GlyphMeasure {
        var character: String
        var rect: CGRect
        var fontSize: CGFloat
        var strokeRatio: CGFloat
        var slant: CGFloat
        var serifScore: CGFloat
        var charWidth: CGFloat
        var reliableSize: Bool
        var reliableStroke: Bool
        var color: (CGFloat, CGFloat, CGFloat)
        var isBreak = false

        static func plain(_ character: String) -> GlyphMeasure {
            GlyphMeasure(
                character: character,
                rect: .zero,
                fontSize: 0,
                strokeRatio: 0,
                slant: 0,
                serifScore: 1,
                charWidth: 0,
                reliableSize: false,
                reliableStroke: false,
                color: (0.07, 0.07, 0.07)
            )
        }
    }

    private struct RunAccum {
        var text = ""
        var rects: [CGRect] = []
        var sizes: [CGFloat] = []
        var strokes: [CGFloat] = []
        var slants: [CGFloat] = []
        var serifs: [CGFloat] = []
        var widths: [CGFloat] = []
        var colors: [(CGFloat, CGFloat, CGFloat)] = []

        var hasReliable: Bool { !sizes.isEmpty }

        mutating func append(_ glyph: GlyphMeasure) {
            text += glyph.character
            if glyph.rect.width > 0, glyph.rect.height > 0 {
                rects.append(glyph.rect)
            }
            if glyph.reliableSize, glyph.fontSize > 0 {
                sizes.append(glyph.fontSize)
            }
            if glyph.reliableStroke, glyph.strokeRatio > 0 {
                strokes.append(glyph.strokeRatio)
                slants.append(glyph.slant)
                serifs.append(glyph.serifScore)
                widths.append(glyph.charWidth)
                colors.append(glyph.color)
            } else if glyph.reliableSize {
                colors.append(glyph.color)
            }
        }

        mutating func absorb(_ other: RunAccum) {
            text += other.text
            rects.append(contentsOf: other.rects)
            sizes.append(contentsOf: other.sizes)
            strokes.append(contentsOf: other.strokes)
            slants.append(contentsOf: other.slants)
            serifs.append(contentsOf: other.serifs)
            widths.append(contentsOf: other.widths)
            colors.append(contentsOf: other.colors)
        }

        func accepts(_ glyph: GlyphMeasure) -> Bool {
            if glyph.character == " " || !glyph.reliableSize { return true }
            guard let size = FontStyleReader.median(sizes), size > 0.004 else { return true }
            if abs(glyph.fontSize - size) / size > 0.18 { return false }
            if glyph.reliableStroke, let weight = FontStyleReader.median(strokes), strokes.count >= 2 {
                if abs(glyph.strokeRatio - weight) > 0.05 { return false }
            }
            return true
        }

        func makeRun(lineRect: CGRect, raster: PageRaster?) -> OCRTextRun? {
            let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !visible.isEmpty else { return nil }
            let size = min(max(FontStyleReader.median(sizes) ?? lineRect.height * 0.78, 0.008), 0.14)
            let weight = FontStyleReader.median(strokes) ?? 0
            let slant = FontStyleReader.median(slants) ?? 0
            let serif = FontStyleReader.median(serifs) ?? 1
            let heights = rects.map(\.height).filter { $0 > 0.003 }
            let band = FontStyleReader.median(heights) ?? lineRect.height
            let union = rects.reduce(rects.first ?? lineRect) { $0.union($1) }
            var rect = union.width > 0 ? union : lineRect
            if band > 0 {
                let padded = min(max(rect.height, band * 1.08), band * 1.28)
                let mid = FontStyleReader.median(rects.map(\.midY)) ?? rect.midY
                rect.origin.y = mid - padded / 2
                rect.size.height = padded
            }
            rect = rect.insetBy(dx: -0.0006, dy: -0.0003).clampedNormalized()
            let underlined = raster?.hasUnderline(in: rect) ?? false
            return OCRTextRun(
                text: text,
                rect: rect,
                fontSize: size,
                fontName: FontStyleReader.fontName(serif: serif, widths: widths),
                isBold: weight >= 0.15,
                isItalic: slants.count >= 3 && slant > 0.15,
                isUnderline: underlined,
                colorHex: FontStyleReader.hexColor(colors)
            )
        }
    }

    private static func measureGlyphs(in candidate: VNRecognizedText, raster: PageRaster?) -> [GlyphMeasure] {
        let string = candidate.string
        var glyphs: [GlyphMeasure] = []
        var index = string.startIndex
        var count = 0
        while index < string.endIndex, count < 500 {
            let next = string.index(after: index)
            let token = String(string[index])
            count += 1
            defer { index = next }
            if token == "\n" {
                var br = GlyphMeasure.plain("\n")
                br.isBreak = true
                glyphs.append(br)
                continue
            }
            if token == "\t" { continue }
            if token.trimmingCharacters(in: .whitespaces).isEmpty {
                glyphs.append(.plain(" "))
                continue
            }
            guard let observation = try? candidate.boundingBox(for: index..<next) else {
                var missing = GlyphMeasure.plain(token)
                missing.character = token
                glyphs.append(missing)
                continue
            }
            let rect = CGRect(
                x: observation.boundingBox.origin.x,
                y: 1 - observation.boundingBox.origin.y - observation.boundingBox.height,
                width: observation.boundingBox.width,
                height: observation.boundingBox.height
            ).clampedNormalized()
            let ink = raster?.metrics(in: rect)
            let estimated = estimatedFontSize(token, height: rect.height)
            let wideEnough = rect.width > rect.height * 0.38
            glyphs.append(GlyphMeasure(
                character: token,
                rect: rect,
                fontSize: estimated,
                strokeRatio: ink?.strokeRatio ?? 0,
                slant: ink?.slant ?? 0,
                serifScore: ink?.serifScore ?? 1,
                charWidth: rect.width,
                reliableSize: estimated > 0 && rect.height > 0.004,
                reliableStroke: wideEnough && ink != nil,
                color: ink?.color ?? (0.07, 0.07, 0.07)
            ))
        }
        return glyphs
    }

    /// Breaks a Vision paragraph into visual lines, then into words, so a tap edits one word.
    private static func wordRuns(from glyphs: [GlyphMeasure], fallback: CGRect, raster: PageRaster?) -> [OCRTextRun] {
        let lines = splitLines(glyphs)
        var runs: [OCRTextRun] = []
        for line in lines {
            for word in wordGroups(line) {
                guard let wordRect = unionRect(of: word) else { continue }
                let pieces = styleRuns(from: word, lineRect: wordRect, raster: raster)
                if pieces.isEmpty {
                    let text = word.map(\.character).joined()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    runs.append(fallbackRun(text: text, lineRect: wordRect, raster: raster))
                } else if let main = pieces.max(by: { $0.text.count < $1.text.count }) {
                    let text = pieces.map(\.text).joined()
                    let rect = pieces.dropFirst().reduce(pieces[0].rect) { $0.union($1.rect) }
                    runs.append(OCRTextRun(
                        text: text,
                        rect: rect,
                        fontSize: main.fontSize,
                        fontName: main.fontName,
                        isBold: main.isBold,
                        isItalic: main.isItalic,
                        isUnderline: pieces.contains(where: \.isUnderline),
                        colorHex: main.colorHex
                    ))
                }
            }
        }
        if runs.isEmpty {
            let text = glyphs.map(\.character).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [fallbackRun(text: text, lineRect: fallback, raster: raster)]
        }
        return runs
    }

    private static func unionRect(of glyphs: [GlyphMeasure]) -> CGRect? {
        let rects = glyphs.compactMap { glyph -> CGRect? in
            guard glyph.rect.width > 0.001, glyph.rect.height > 0.001 else { return nil }
            return glyph.rect
        }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func splitLines(_ glyphs: [GlyphMeasure]) -> [[GlyphMeasure]] {
        var lines: [[GlyphMeasure]] = []
        var current: [GlyphMeasure] = []
        var anchorY: CGFloat?
        var anchorH: CGFloat = 0

        func flush() {
            if current.contains(where: { !$0.isBreak && !$0.character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                lines.append(current.filter { !$0.isBreak })
            }
            current = []
            anchorY = nil
            anchorH = 0
        }

        for glyph in glyphs {
            if glyph.isBreak {
                flush()
                continue
            }
            if glyph.rect.height > 0.003, let anchorY {
                let limit = max(anchorH, glyph.rect.height) * 0.55
                if abs(glyph.rect.midY - anchorY) > limit {
                    flush()
                }
            }
            if anchorY == nil, glyph.rect.height > 0.003 {
                anchorY = glyph.rect.midY
                anchorH = glyph.rect.height
            }
            current.append(glyph)
        }
        flush()
        return lines
    }

    private static func wordGroups(_ glyphs: [GlyphMeasure]) -> [[GlyphMeasure]] {
        var words: [[GlyphMeasure]] = []
        var current: [GlyphMeasure] = []

        func flush() {
            if current.contains(where: { !$0.character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                words.append(current)
            }
            current = []
        }

        for glyph in glyphs {
            if glyph.character == " " {
                flush()
            } else {
                current.append(glyph)
            }
        }
        flush()
        return words
    }

    private static func styleRuns(from glyphs: [GlyphMeasure], lineRect: CGRect, raster: PageRaster?) -> [OCRTextRun] {
        var accums: [RunAccum] = []
        for glyph in glyphs {
            if var last = accums.last, last.accepts(glyph) {
                last.append(glyph)
                accums[accums.count - 1] = last
            } else {
                var run = RunAccum()
                run.append(glyph)
                accums.append(run)
            }
        }
        var merged: [RunAccum] = []
        for accum in accums {
            if !accum.hasReliable, !merged.isEmpty {
                merged[merged.count - 1].absorb(accum)
            } else {
                merged.append(accum)
            }
        }
        return merged.compactMap { $0.makeRun(lineRect: lineRect, raster: raster) }
    }

    private static func fallbackRun(text: String, lineRect: CGRect, raster: PageRaster?) -> OCRTextRun {
        let ink = raster?.metrics(in: lineRect)
        let size = min(max(lineRect.height * 0.78, 0.008), 0.14)
        return OCRTextRun(
            text: text,
            rect: lineRect,
            fontSize: size,
            fontName: fontName(serif: ink?.serifScore ?? 1, widths: []),
            isBold: (ink?.strokeRatio ?? 0) >= 0.15,
            isItalic: (ink?.slant ?? 0) > 0.15,
            isUnderline: raster?.hasUnderline(in: lineRect) ?? false,
            colorHex: hexColor(ink.map { [$0.color] } ?? [])
        )
    }

    private static func estimatedFontSize(_ token: String, height: CGFloat) -> CGFloat {
        guard height > 0, let scalar = token.unicodeScalars.first else { return 0 }
        if CharacterSet.uppercaseLetters.contains(scalar) || "bdfhklt".contains(token) {
            return height / 0.72
        }
        if CharacterSet.decimalDigits.contains(scalar) {
            return height / 0.70
        }
        if "gjpqy".contains(token) {
            return height / 0.78
        }
        if CharacterSet.letters.contains(scalar) {
            return height / 0.53
        }
        return 0
    }

    private static func fontName(serif: CGFloat, widths: [CGFloat]) -> String {
        if widths.count >= 6, let spread = coefficientOfVariation(widths), spread < 0.11 {
            return "Courier New"
        }
        if serif > 1.55 {
            return "Times New Roman"
        }
        return "Helvetica"
    }

    private static func hexColor(_ samples: [(CGFloat, CGFloat, CGFloat)]) -> String {
        guard !samples.isEmpty else { return "#111111" }
        let r = samples.map(\.0).reduce(0, +) / CGFloat(samples.count)
        let g = samples.map(\.1).reduce(0, +) / CGFloat(samples.count)
        let b = samples.map(\.2).reduce(0, +) / CGFloat(samples.count)
        let red = Int((r * 255).rounded())
        let green = Int((g * 255).rounded())
        let blue = Int((b * 255).rounded())
        let spread = max(red, green, blue) - min(red, green, blue)
        let luma = (red + green + blue) / 3
        if spread < 28, luma < 90 { return "#111111" }
        if luma > 230 { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func coefficientOfVariation(_ values: [CGFloat]) -> CGFloat? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / CGFloat(values.count)
        guard mean > 0.0001 else { return nil }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(values.count)
        return sqrt(variance) / mean
    }
}

private struct InkMetrics {
    var strokeRatio: CGFloat
    var slant: CGFloat
    var serifScore: CGFloat
    var color: (CGFloat, CGFloat, CGFloat)
}

private struct PageRaster {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(image: UIImage) {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > 1, image.size.width > 1, image.size.height > 1 else { return nil }
        let scale = min(1, 1400 / longSide)
        let pixelWidth = max(Int((image.size.width * scale).rounded(.down)), 1)
        let pixelHeight = max(Int((image.size.height * scale).rounded(.down)), 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: pixelWidth, height: pixelHeight),
            format: format
        ).image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)).fill()
            image.draw(in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        guard let cgImage = rendered.cgImage else { return nil }
        let rowBytes = pixelWidth * 4
        var buffer = [UInt8](repeating: 255, count: pixelHeight * rowBytes)
        let copied = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard copied else { return nil }
        width = pixelWidth
        height = pixelHeight
        bytes = buffer
    }

    func metrics(in rect: CGRect) -> InkMetrics? {
        let bounds = pixelBounds(rect)
        guard let bounds else { return nil }
        let background = borderLuma(bounds)
        guard !background.isEmpty else { return nil }
        let sorted = background.sorted()
        let paper = sorted[sorted.count / 2]
        let inkIsDark = paper > 110
        return measure(bounds: bounds, paper: paper, inkIsDark: inkIsDark)
    }

    func hasUnderline(in rect: CGRect) -> Bool {
        let band = CGRect(
            x: rect.minX,
            y: min(0.99, max(0, rect.maxY - rect.height * 0.2)),
            width: rect.width,
            height: min(0.025, max(rect.height * 0.32, 0.004))
        ).clampedNormalized()
        guard let bounds = pixelBounds(band) else { return false }
        let background = borderLuma(bounds)
        guard !background.isEmpty else { return false }
        let paper = background.sorted()[background.count / 2]
        let inkIsDark = paper > 110
        var longest = 0
        for y in bounds.y0..<bounds.y1 {
            var run = 0
            for x in bounds.x0..<bounds.x1 {
                if isInk(x: x, yTop: y, paper: paper, inkIsDark: inkIsDark) {
                    run += 1
                    longest = max(longest, run)
                } else {
                    run = 0
                }
            }
        }
        return longest > Int(CGFloat(bounds.x1 - bounds.x0) * 0.55)
    }

    private struct Bounds {
        var x0: Int
        var x1: Int
        var y0: Int
        var y1: Int
    }

    private func pixelBounds(_ rect: CGRect) -> Bounds? {
        let x0 = max(0, min(width - 1, Int(rect.minX * CGFloat(width))))
        let x1 = max(x0 + 1, min(width, Int(ceil(rect.maxX * CGFloat(width)))))
        let y0 = max(0, min(height - 1, Int(rect.minY * CGFloat(height))))
        let y1 = max(y0 + 1, min(height, Int(ceil(rect.maxY * CGFloat(height)))))
        guard x1 - x0 >= 2, y1 - y0 >= 3 else { return nil }
        return Bounds(x0: x0, x1: x1, y0: y0, y1: y1)
    }

    private func borderLuma(_ bounds: Bounds) -> [Int] {
        var values: [Int] = []
        for x in bounds.x0..<bounds.x1 {
            if let top = pixel(x: x, yTop: bounds.y0) { values.append(top.luma) }
            if let bottom = pixel(x: x, yTop: bounds.y1 - 1) { values.append(bottom.luma) }
        }
        for y in bounds.y0..<bounds.y1 {
            if let left = pixel(x: bounds.x0, yTop: y) { values.append(left.luma) }
            if let right = pixel(x: bounds.x1 - 1, yTop: y) { values.append(right.luma) }
        }
        return values
    }

    private func measure(bounds: Bounds, paper: Int, inkIsDark: Bool) -> InkMetrics? {
        let pixelWidth = bounds.x1 - bounds.x0
        let pixelHeight = bounds.y1 - bounds.y0
        let midY0 = bounds.y0 + pixelHeight * 30 / 100
        let midY1 = bounds.y0 + pixelHeight * 70 / 100
        let topY1 = bounds.y0 + max(pixelHeight * 22 / 100, 1)
        let slantTop1 = bounds.y0 + pixelHeight * 35 / 100
        let slantBot0 = bounds.y0 + pixelHeight * 65 / 100
        var inkCount = 0
        var redSum = 0
        var greenSum = 0
        var blueSum = 0
        var runs: [Int] = []
        var topInk = 0
        var midInk = 0
        var midRows = 0
        var topCenter = 0
        var topCount = 0
        var bottomCenter = 0
        var bottomCount = 0

        for y in bounds.y0..<bounds.y1 {
            var run = 0
            var rowInk = 0
            for x in bounds.x0..<bounds.x1 {
                guard let sample = pixel(x: x, yTop: y) else { continue }
                let ink = inkIsDark ? sample.luma + 32 < paper : sample.luma > paper + 32
                if ink {
                    inkCount += 1
                    rowInk += 1
                    redSum += sample.r
                    greenSum += sample.g
                    blueSum += sample.b
                    run += 1
                    if y < slantTop1 {
                        topCenter += x
                        topCount += 1
                    } else if y >= slantBot0 {
                        bottomCenter += x
                        bottomCount += 1
                    }
                } else if run > 0 {
                    if y >= midY0, y < midY1, run < pixelWidth * 3 / 5 {
                        runs.append(run)
                    }
                    run = 0
                }
            }
            if run > 0, y >= midY0, y < midY1, run < pixelWidth * 3 / 5 {
                runs.append(run)
            }
            if y < topY1 { topInk += rowInk }
            if y >= midY0, y < midY1 {
                midInk += rowInk
                midRows += 1
            }
        }
        guard inkCount >= 4 else { return nil }
        runs.sort()
        let stroke = runs.isEmpty ? 1 : runs[runs.count / 2]
        let strokeRatio = CGFloat(stroke) / CGFloat(max(pixelHeight, 1))
        var slant: CGFloat = 0
        if topCount > 3, bottomCount > 3 {
            let top = CGFloat(topCenter) / CGFloat(topCount)
            let bottom = CGFloat(bottomCenter) / CGFloat(bottomCount)
            slant = (top - bottom) / CGFloat(max(pixelHeight, 1))
        }
        let stem = midRows > 0 ? CGFloat(midInk) / CGFloat(midRows) : 1
        let topRows = max(topY1 - bounds.y0, 1)
        let topMean = CGFloat(topInk) / CGFloat(topRows)
        let serif = topMean / max(stem, 1)
        return InkMetrics(
            strokeRatio: strokeRatio,
            slant: slant,
            serifScore: serif,
            color: (
                CGFloat(redSum) / CGFloat(inkCount) / 255,
                CGFloat(greenSum) / CGFloat(inkCount) / 255,
                CGFloat(blueSum) / CGFloat(inkCount) / 255
            )
        )
    }

    private func isInk(x: Int, yTop: Int, paper: Int, inkIsDark: Bool) -> Bool {
        guard let sample = pixel(x: x, yTop: yTop) else { return false }
        return inkIsDark ? sample.luma + 32 < paper : sample.luma > paper + 32
    }

    private func pixel(x: Int, yTop: Int) -> (r: Int, g: Int, b: Int, luma: Int)? {
        guard x >= 0, yTop >= 0, x < width, yTop < height else { return nil }
        let y = height - 1 - yTop
        let offset = (y * width + x) * 4
        guard offset + 2 < bytes.count else { return nil }
        let r = Int(bytes[offset])
        let g = Int(bytes[offset + 1])
        let b = Int(bytes[offset + 2])
        let luma = (r * 54 + g * 183 + b * 19) / 256
        return (r, g, b, luma)
    }
}
