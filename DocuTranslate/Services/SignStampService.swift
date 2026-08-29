import UIKit
import PencilKit
import Vision

// MARK: - Sign & Stamp Service

class SignStampService {
    static let shared = SignStampService()
    private init() {}

    private let savedSignaturesKey = "savedSignatures"
    private let savedStampsKey = "savedStamps"
    private let maxStoredStamps = 20

    // MARK: - Composite

    func composite(
        base: UIImage,
        signature: PlacedOverlay?,
        stamp: PlacedOverlay?,
        date: PlacedOverlay? = nil,
        signatureLine: PlacedOverlay? = nil
    ) -> UIImage {
        let size = base.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = base.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            base.draw(at: .zero)
            if let stamp { draw(overlay: stamp, on: size) }
            if let date { draw(overlay: date, on: size) }
            if let signatureLine { draw(overlay: signatureLine, on: size) }
            if let signature { draw(overlay: signature, on: size) }
        }
    }

    private func draw(overlay: PlacedOverlay, on canvasSize: CGSize) {
        guard let image = overlay.image else { return }
        let width = canvasSize.width * overlay.relativeWidth
        let aspect = image.size.height / max(image.size.width, 1)
        let height = width * aspect
        let center = CGPoint(
            x: canvasSize.width * overlay.centerX,
            y: canvasSize.height * overlay.centerY
        )
        let rect = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )

        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(overlay.rotation * .pi / 180))
        ctx.translateBy(x: -center.x, y: -center.y)
        image.draw(in: rect, blendMode: .normal, alpha: overlay.opacity)
        ctx.restoreGState()
    }

    // MARK: - Stamp Generation

    func makeStamp(text: String, style: StampStyle) -> UIImage {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = raw.isEmpty ? "STAMP" : raw.uppercased()
        let lines = Self.wrappedStampLines(label)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false

        let maxTextWidth: CGFloat = 280
        var fontSize = min(max(style.fontSize, 18), 34)
        var font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        var lineSizes: [CGSize] = []
        var textW: CGFloat = 0
        var textH: CGFloat = 0

        func measure() {
            lineSizes = lines.map { ($0 as NSString).size(withAttributes: [.font: font]) }
            textW = lineSizes.map(\.width).max() ?? 0
            textH = lineSizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, lines.count - 1)) * 3
        }

        measure()
        while fontSize > 11 && (textW > maxTextWidth || textH > 90) {
            fontSize -= 1
            font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
            measure()
        }

        let hPad: CGFloat = 26
        let vPad: CGFloat = 16
        var size = CGSize(width: ceil(textW + hPad * 2), height: ceil(textH + vPad * 2))

        if style.shape == .oval {
            let diameter = max(size.width, size.height) + 12
            size = CGSize(width: diameter, height: diameter * 0.72)
        }

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            cg.setStrokeColor(style.color.cgColor)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)

            if style.shape == .oval {
                cg.setLineWidth(5)
                cg.strokeEllipse(in: rect.insetBy(dx: 4, dy: 4))
                cg.setLineWidth(1.6)
                cg.strokeEllipse(in: rect.insetBy(dx: 11, dy: 11))
            } else {
                let corner = min(10, size.height * 0.2)
                let outer = UIBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerRadius: corner)
                cg.setLineWidth(4.5)
                cg.addPath(outer.cgPath)
                cg.strokePath()

                let inner = UIBezierPath(
                    roundedRect: rect.insetBy(dx: 10, dy: 10),
                    cornerRadius: max(5, corner - 4)
                )
                cg.setLineWidth(1.6)
                cg.addPath(inner.cgPath)
                cg.strokePath()
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byClipping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: style.color,
                .paragraphStyle: paragraph,
                .kern: 1.1
            ]

            var y = (size.height - textH) / 2
            for (i, line) in lines.enumerated() {
                let h = lineSizes[i].height
                let drawRect = CGRect(x: 10, y: y, width: size.width - 20, height: h)
                (line as NSString).draw(in: drawRect, withAttributes: attrs)
                y += h + 3
            }
        }
    }

    private static func wrappedStampLines(_ text: String) -> [String] {
        let split = text
            .replacingOccurrences(of: "|", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if split.count > 1 {
            return Array(split.prefix(3))
        }

        if text.count <= 14 { return [text] }

        let words = text.split(separator: " ").map(String.init)
        if words.count >= 2 {
            let mid = (words.count + 1) / 2
            return [
                words.prefix(mid).joined(separator: " "),
                words.suffix(from: mid).joined(separator: " ")
            ]
        }

        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        return [String(text[..<mid]), String(text[mid...])]
    }

    func makeDateLine(date: Date, color: UIColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)) -> UIImage {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return makeUnderlinedLabel(prefix: "Dated", value: formatter.string(from: date), color: color)
    }

    func makeSignatureLine(name: String = "", color: UIColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)) -> UIImage {
        makeUnderlinedLabel(prefix: "Signature", value: name, blankWidth: 18, color: color)
    }

    func makeUnderlinedLabel(
        prefix: String,
        value: String,
        blankWidth: Int = 12,
        color: UIColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
    ) -> UIImage {
        let filled = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = filled.isEmpty ? String(repeating: "_", count: blankWidth) : filled.uppercased()
        let label = "\(prefix.uppercased()): \(body)"
        let font = UIFont.systemFont(ofSize: 22, weight: .bold)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(textSize.width) + 16, height: ceil(textSize.height) + 18)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .kern: 0.6
            ]
            (label as NSString).draw(at: CGPoint(x: 8, y: 2), withAttributes: attrs)
            let cg = ctx.cgContext
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(1.6)
            let y = size.height - 5
            cg.move(to: CGPoint(x: 8, y: y))
            cg.addLine(to: CGPoint(x: size.width - 8, y: y))
            cg.strokePath()
        }
    }

    func signatureFromCanvas(_ canvas: PKCanvasView) -> UIImage? {
        let drawing = canvas.drawing
        guard !drawing.strokes.isEmpty else { return nil }

        let bounds = drawing.bounds.insetBy(dx: -12, dy: -12)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        return drawing.image(from: bounds, scale: UIScreen.main.scale)
    }

    func stampFromCanvas(_ canvas: PKCanvasView) -> UIImage? {
        guard let image = signatureFromCanvas(canvas) else { return nil }
        return processImportedStamp(image)
    }

    // MARK: - Saved Signatures

    func loadSavedSignatures() -> [SavedSignature] {
        guard let data = UserDefaults.standard.data(forKey: savedSignaturesKey),
              let items = try? JSONDecoder().decode([SavedSignature].self, from: data) else {
            return []
        }
        return items
    }

    func saveSignature(_ image: UIImage, name: String = "My Signature") {
        guard let data = image.pngData() else { return }
        var items = loadSavedSignatures()
        items.insert(SavedSignature(name: name, imageData: data), at: 0)
        if items.count > 5 { items = Array(items.prefix(5)) }
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: savedSignaturesKey)
        }
    }

    func deleteSavedSignature(id: UUID) {
        var items = loadSavedSignatures()
        items.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: savedSignaturesKey)
        }
    }

    // MARK: - Image interpretation (OCR + cleanup)

    func interpretStampImage(_ image: UIImage) async -> StampInterpretation {
        let prepared = Self.prepareForProcessing(image)
        let cleaned = processImportedStamp(prepared)
        async let recognized = recognizeStampText(in: prepared)
        let text = await recognized
        let color = Self.dominantInkColor(in: prepared)
        return StampInterpretation(
            recognizedText: text,
            inkColor: color,
            cleanedImage: cleaned
        )
    }

    func recognizeStampText(in image: UIImage) async -> String {
        let prepared = Self.prepareForProcessing(image)
        guard let cgImage = prepared.cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.04
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let joined = lines.joined(separator: " ")
        return Self.normalizeRecognizedStampText(joined)
    }

    func shouldRecreateFromOCR(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...36).contains(trimmed.count) else { return false }
        let letters = trimmed.filter(\.isLetter).count
        return Double(letters) / Double(trimmed.count) >= 0.55
    }

    // MARK: - Blueprint stamps (AI / company seals)

    func makeStamp(from spec: StampBlueprint) -> UIImage {
        if spec.isSeal {
            return makeSealStamp(spec)
        }
        let parts = spec.composedLines
        if parts.isEmpty {
            return makeStamp(text: "STAMP", style: StampStyle(color: spec.color, fontSize: 20, shape: spec.shape))
        }
        return makeStamp(
            text: parts.joined(separator: "\n"),
            style: StampStyle(color: spec.color, fontSize: spec.subtitle.isEmpty && spec.dateText.isEmpty ? 22 : 18, shape: spec.shape)
        )
    }

    private func makeSealStamp(_ spec: StampBlueprint) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let size = CGSize(width: 320, height: 320)
        let lines = spec.composedLines
        let color = spec.color

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            cg.setStrokeColor(color.cgColor)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            cg.setLineWidth(8)
            cg.strokeEllipse(in: rect.insetBy(dx: 8, dy: 8))
            cg.setLineWidth(2.2)
            cg.strokeEllipse(in: rect.insetBy(dx: 20, dy: 20))

            let inner = rect.insetBy(dx: 36, dy: 36)
            cg.setLineWidth(1)
            cg.strokeEllipse(in: inner)

            let usable = rect.insetBy(dx: 48, dy: 56)
            let count = max(lines.count, 1)
            let slotH = usable.height / CGFloat(count)
            let maxFont: CGFloat = count == 1 ? 28 : (count == 2 ? 22 : 18)

            for (index, line) in lines.enumerated() {
                var fontSize = maxFont
                if index > 0 { fontSize = min(fontSize, 16) }
                var font = UIFont.systemFont(ofSize: fontSize, weight: index == 0 ? .heavy : .bold)
                var textSize = (line as NSString).size(withAttributes: [.font: font])
                while fontSize > 9 && textSize.width > usable.width {
                    fontSize -= 1
                    font = UIFont.systemFont(ofSize: fontSize, weight: index == 0 ? .heavy : .semibold)
                    textSize = (line as NSString).size(withAttributes: [.font: font])
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                    .kern: 0.8
                ]
                let y = usable.minY + CGFloat(index) * slotH + (slotH - textSize.height) / 2
                (line as NSString).draw(
                    in: CGRect(x: usable.minX, y: y, width: usable.width, height: textSize.height + 4),
                    withAttributes: attrs
                )
            }
        }
    }

    // MARK: - Imported Stamp Processing

    /// Isolates stamp ink/graphics and makes paper, JPEG haze, and grey halos fully transparent.
    func processImportedStamp(_ image: UIImage) -> UIImage {
        let prepared = Self.prepareForProcessing(image, maxSide: 1200)
        guard let cgImage = prepared.cgImage else { return prepared }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 8, height > 8 else { return prepared }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return prepared }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return prepared }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let count = width * height

        let paper = Self.estimatePaperColor(pixels: pixels, width: width, height: height)

        var ink = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let p = i * 4
            let r = CGFloat(pixels[p]) / 255
            let g = CGFloat(pixels[p + 1]) / 255
            let b = CGFloat(pixels[p + 2]) / 255
            let a = CGFloat(pixels[p + 3]) / 255
            ink[i] = (a > 0.08 && Self.isStampInk(r: r, g: g, b: b, paper: paper)) ? 1 : 0
        }

        Self.floodFillBackground(ink: &ink, width: width, height: height, pixels: pixels)
        ink = Self.majorityFilter(ink, width: width, height: height)
        Self.removeHalo(ink: &ink, width: width, height: height, pixels: pixels)

        var minX = width, minY = height, maxX = 0, maxY = 0
        var kept = 0

        for i in 0..<count {
            let p = i * 4
            if ink[i] == 0 {
                pixels[p] = 0
                pixels[p + 1] = 0
                pixels[p + 2] = 0
                pixels[p + 3] = 0
                continue
            }

            let r = CGFloat(pixels[p]) / 255
            let g = CGFloat(pixels[p + 1]) / 255
            let b = CGFloat(pixels[p + 2]) / 255
            let sat = max(r, g, b) - min(r, g, b)
            let luma = Self.luma(r, g, b)
            let x = i % width
            let y = i / width
            let edge = Self.hasEmptyNeighbor(ink, width: width, height: height, x: x, y: y)

            var alpha: CGFloat = 1
            if edge && sat < 0.18 && luma > 0.42 {
                alpha = 0
            } else if edge {
                alpha = 0.92
            }

            if alpha < 0.08 {
                pixels[p] = 0; pixels[p + 1] = 0; pixels[p + 2] = 0; pixels[p + 3] = 0
                continue
            }

            pixels[p + 3] = UInt8(alpha * 255)
            kept += 1
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }

        guard kept > 40, minX < maxX, minY < maxY,
              let processed = ctx.makeImage() else { return prepared }

        let pad = 4
        let cropX = max(0, minX - pad)
        let cropY = max(0, minY - pad)
        let cropW = min(width - cropX, (maxX - minX) + pad * 2)
        let cropH = min(height - cropY, (maxY - minY) + pad * 2)
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)

        guard let cropped = processed.cropping(to: cropRect) else {
            return UIImage(cgImage: processed, scale: 1, orientation: .up)
        }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    // MARK: - Image helpers

    private static func prepareForProcessing(_ image: UIImage, maxSide: CGFloat = 1024) -> UIImage {
        let upright = image.normalizedUp()
        return upright.downscaled(maxSide: maxSide)
    }

    private static func isStampInk(r: CGFloat, g: CGFloat, b: CGFloat, paper: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
        let sat = max(r, g, b) - min(r, g, b)
        let luma = Self.luma(r, g, b)
        let dist = hypot(hypot(r - paper.r, g - paper.g), b - paper.b)
        if sat < 0.12 {
            return luma < 0.46
        }
        return sat > 0.20 || dist > 0.34 || luma < 0.38
    }

    private static func floodFillBackground(
        ink: inout [UInt8],
        width: Int,
        height: Int,
        pixels: UnsafeMutablePointer<UInt8>
    ) {
        var visited = [UInt8](repeating: 0, count: width * height)
        var queue: [Int] = []
        queue.reserveCapacity(width + height)

        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let i = y * width + x
            guard visited[i] == 0 else { return }
            visited[i] = 1

            let p = i * 4
            let r = CGFloat(pixels[p]) / 255
            let g = CGFloat(pixels[p + 1]) / 255
            let b = CGFloat(pixels[p + 2]) / 255
            let sat = max(r, g, b) - min(r, g, b)
            let luma = Self.luma(r, g, b)
            let weak = ink[i] == 0 || (sat < 0.18 && luma > 0.40)
            if weak {
                ink[i] = 0
                queue.append(i)
            }
        }

        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }
        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }

        var head = 0
        while head < queue.count {
            let i = queue[head]
            head += 1
            let x = i % width
            let y = i / width
            enqueue(x - 1, y)
            enqueue(x + 1, y)
            enqueue(x, y - 1)
            enqueue(x, y + 1)
        }
    }

    private static func majorityFilter(_ ink: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = ink
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var votes = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        votes += Int(ink[(y + dy) * width + (x + dx)])
                    }
                }
                output[y * width + x] = votes >= 5 ? 1 : 0
            }
        }
        return output
    }

    private static func removeHalo(
        ink: inout [UInt8],
        width: Int,
        height: Int,
        pixels: UnsafeMutablePointer<UInt8>
    ) {
        var next = ink
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                guard ink[i] == 1 else { continue }
                let p = i * 4
                let r = CGFloat(pixels[p]) / 255
                let g = CGFloat(pixels[p + 1]) / 255
                let b = CGFloat(pixels[p + 2]) / 255
                let sat = max(r, g, b) - min(r, g, b)
                let luma = Self.luma(r, g, b)
                if sat < 0.16 && luma > 0.48 && hasEmptyNeighbor(ink, width: width, height: height, x: x, y: y) {
                    next[i] = 0
                }
            }
        }
        ink = next
    }

    private static func hasEmptyNeighbor(_ ink: [UInt8], width: Int, height: Int, x: Int, y: Int) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 {
                if dx == 0 && dy == 0 { continue }
                let nx = x + dx, ny = y + dy
                if nx < 0 || ny < 0 || nx >= width || ny >= height { return true }
                if ink[ny * width + nx] == 0 { return true }
            }
        }
        return false
    }

    private static func estimatePaperColor(pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let sample = max(4, min(width, height) / 30)
        var rs: [CGFloat] = []
        var gs: [CGFloat] = []
        var bs: [CGFloat] = []

        func sampleCorner(ox: Int, oy: Int) {
            for y in oy..<(oy + sample) {
                for x in ox..<(ox + sample) {
                    guard x >= 0, y >= 0, x < width, y < height else { continue }
                    let i = (y * width + x) * 4
                    rs.append(CGFloat(pixels[i]) / 255)
                    gs.append(CGFloat(pixels[i + 1]) / 255)
                    bs.append(CGFloat(pixels[i + 2]) / 255)
                }
            }
        }

        sampleCorner(ox: 0, oy: 0)
        sampleCorner(ox: width - sample, oy: 0)
        sampleCorner(ox: 0, oy: height - sample)
        sampleCorner(ox: width - sample, oy: height - sample)

        func median(_ values: [CGFloat]) -> CGFloat {
            guard !values.isEmpty else { return 0.95 }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        return (median(rs), median(gs), median(bs))
    }

    private static func luma(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        0.299 * r + 0.587 * g + 0.114 * b
    }

    private static func dominantInkColor(in image: UIImage) -> UIColor {
        let small = prepareForProcessing(image, maxSide: 240)
        guard let cgImage = small.cgImage else { return StampStyle.inkRed }

        let width = cgImage.width
        let height = cgImage.height
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return StampStyle.inkRed }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return StampStyle.inkRed }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var rSum: CGFloat = 0, gSum: CGFloat = 0, bSum: CGFloat = 0
        var count: CGFloat = 0

        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = CGFloat(pixels[i]) / 255
                let g = CGFloat(pixels[i + 1]) / 255
                let b = CGFloat(pixels[i + 2]) / 255
                let sat = max(r, g, b) - min(r, g, b)
                let luma = Self.luma(r, g, b)
                if sat > 0.18 && luma < 0.86 {
                    rSum += r; gSum += g; bSum += b
                    count += 1
                }
            }
        }

        guard count > 20 else { return StampStyle.inkRed }
        return UIColor(red: rSum / count, green: gSum / count, blue: bSum / count, alpha: 1)
    }

    private static func normalizeRecognizedStampText(_ raw: String) -> String {
        let cleaned = raw
            .uppercased()
            .replacingOccurrences(of: "[^A-Z0-9 \\-/&.]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "" }

        let compact = cleaned.replacingOccurrences(of: " ", with: "")
        let aliases: [String: String] = [
            "CANCELED": "CANCELLED",
            "CENCELLED": "CANCELLED",
            "CENCELED": "CANCELLED",
            "CANCELL": "CANCELLED",
            "CANCEL": "CANCELLED",
            "CONFIDENT1AL": "CONFIDENTIAL",
            "CONFIDENTAL": "CONFIDENTIAL",
            "APROVED": "APPROVED",
            "APPPROVED": "APPROVED",
            "RECIEVED": "RECEIVED",
            "VERIFED": "VERIFIED"
        ]
        if let mapped = aliases[compact] { return mapped }

        for (name, _) in StampStyle.presets {
            let target = name.uppercased().replacingOccurrences(of: " ", with: "")
            if compact == target { return name.uppercased() }
            if compact.count >= 4 && target.count >= 4 && levenshtein(compact, target) <= 2 {
                return name.uppercased()
            }
        }

        if cleaned.count > 40 {
            return String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        let n = aChars.count, m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev = Array(0...m)
        var current = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            current[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(prev[j] + 1, current[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = current
        }
        return prev[m]
    }

    // MARK: - Saved Stamps (file-backed so camera images actually persist)

    private var stampsDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SavedStamps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func stampFileURL(_ fileName: String) -> URL {
        stampsDirectory.appendingPathComponent(fileName)
    }

    func image(for stamp: SavedStamp) -> UIImage? {
        if let fileName = stamp.fileName {
            let url = stampFileURL(fileName)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                return image
            }
        }
        if let imageData = stamp.imageData {
            return UIImage(data: imageData)
        }
        return nil
    }

    func loadSavedStamps() -> [SavedStamp] {
        guard let data = UserDefaults.standard.data(forKey: savedStampsKey),
              var items = try? JSONDecoder().decode([SavedStamp].self, from: data) else {
            return []
        }

        var changed = false
        for i in items.indices {
            if items[i].fileName == nil, let imageData = items[i].imageData, let image = UIImage(data: imageData) {
                items[i] = persistStampImage(image, existing: items[i])
                changed = true
            }
        }
        if changed { writeStampMetadata(items) }
        return items
    }

    func saveStamp(_ image: UIImage, name: String = "My Stamp") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stampName = trimmed.isEmpty ? "My Stamp" : trimmed
        var items = loadSavedStamps()
        let saved = persistStampImage(image, existing: SavedStamp(name: stampName, createdAt: Date()))
        items.insert(saved, at: 0)
        if items.count > maxStoredStamps {
            let removed = items.suffix(from: maxStoredStamps)
            for extra in removed {
                if let fileName = extra.fileName {
                    try? FileManager.default.removeItem(at: stampFileURL(fileName))
                }
            }
            items = Array(items.prefix(maxStoredStamps))
        }
        writeStampMetadata(items)
    }

    func deleteSavedStamp(id: UUID) {
        var items = loadSavedStamps()
        if let match = items.first(where: { $0.id == id }), let fileName = match.fileName {
            try? FileManager.default.removeItem(at: stampFileURL(fileName))
        }
        items.removeAll { $0.id == id }
        writeStampMetadata(items)
    }

    private func persistStampImage(_ image: UIImage, existing: SavedStamp) -> SavedStamp {
        let stored = image.downscaled(maxSide: 768)
        guard let data = stored.pngData() else { return existing }
        let fileName = existing.fileName ?? "\(existing.id.uuidString).png"
        try? data.write(to: stampFileURL(fileName), options: .atomic)
        var updated = existing
        updated.fileName = fileName
        updated.imageData = nil
        return updated
    }

    private func writeStampMetadata(_ items: [SavedStamp]) {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: savedStampsKey)
        }
    }
}

// MARK: - Models

struct PlacedOverlay {
    var image: UIImage?
    var centerX: CGFloat
    var centerY: CGFloat
    var relativeWidth: CGFloat
    var rotation: Double = 0
    var opacity: CGFloat = 1

    static let defaultSignature = PlacedOverlay(centerX: 0.72, centerY: 0.80, relativeWidth: 0.28)
    static let defaultStamp = PlacedOverlay(centerX: 0.28, centerY: 0.78, relativeWidth: 0.28)
    static let defaultDate = PlacedOverlay(centerX: 0.72, centerY: 0.91, relativeWidth: 0.30)
    static let defaultSignatureLine = PlacedOverlay(centerX: 0.55, centerY: 0.86, relativeWidth: 0.40)
}

struct StampStyle {
    let color: UIColor
    let fontSize: CGFloat
    var shape: StampShape = .roundedRect

    enum StampShape: Equatable {
        case roundedRect
        case oval
    }

    static let inkRed = UIColor(red: 0.78, green: 0.12, blue: 0.12, alpha: 1)
    static let inkGreen = UIColor(red: 0.08, green: 0.55, blue: 0.24, alpha: 1)
    static let inkBlue = UIColor(red: 0.10, green: 0.34, blue: 0.84, alpha: 1)
    static let inkPurple = UIColor(red: 0.45, green: 0.15, blue: 0.72, alpha: 1)
    static let inkGray = UIColor(red: 0.38, green: 0.38, blue: 0.38, alpha: 1)
    static let inkOrange = UIColor(red: 0.90, green: 0.45, blue: 0.05, alpha: 1)
    static let inkTeal = UIColor(red: 0.05, green: 0.55, blue: 0.55, alpha: 1)

    static let inkChoices: [(String, UIColor)] = [
        ("Red", inkRed),
        ("Green", inkGreen),
        ("Blue", inkBlue),
        ("Purple", inkPurple),
        ("Orange", inkOrange),
        ("Teal", inkTeal),
        ("Gray", inkGray)
    ]

    static let presets: [(String, StampStyle)] = [
        ("Approved", StampStyle(color: inkGreen, fontSize: 22, shape: .oval)),
        ("Cancelled", StampStyle(color: inkRed, fontSize: 20)),
        ("Confidential", StampStyle(color: inkRed, fontSize: 16)),
        ("Received", StampStyle(color: inkBlue, fontSize: 22)),
        ("Paid", StampStyle(color: inkPurple, fontSize: 24)),
        ("Draft", StampStyle(color: inkGray, fontSize: 24)),
        ("Urgent", StampStyle(color: inkOrange, fontSize: 22)),
        ("Verified", StampStyle(color: inkTeal, fontSize: 20)),
        ("Rejected", StampStyle(color: inkRed, fontSize: 20)),
        ("Copy", StampStyle(color: inkGray, fontSize: 24)),
    ]
}

struct StampInterpretation {
    var recognizedText: String
    var inkColor: UIColor
    var cleanedImage: UIImage
}

struct StampBlueprint: Equatable {
    var title: String = ""
    var subtitle: String = ""
    var dateText: String = ""
    var footer: String = ""
    var colorName: String = "Red"
    var shape: StampStyle.StampShape = .roundedRect
    var isSeal: Bool = false

    var color: UIColor {
        StampStyle.inkChoices.first(where: { $0.0.compare(colorName, options: .caseInsensitive) == .orderedSame })?.1
            ?? StampStyle.inkRed
    }

    var composedLines: [String] {
        [title, subtitle, dateText, footer]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.uppercased() }
    }

    var displayName: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "AI Stamp" : name.capitalized
    }
}

struct SavedSignature: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var imageData: Data
    var createdAt: Date = Date()

    var image: UIImage? { UIImage(data: imageData) }
}

struct SavedStamp: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var imageData: Data? = nil
    var fileName: String? = nil
    var createdAt: Date = Date()

    var image: UIImage? { SignStampService.shared.image(for: self) }
}

enum SignStampTab: String, CaseIterable, Identifiable {
    case signature = "Signature"
    case stamp = "Stamp"
    case date = "Date"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .signature: return "signature"
        case .stamp: return "seal.fill"
        case .date: return "calendar"
        }
    }
}

// MARK: - UIImage helpers

private extension UIImage {
    func normalizedUp() -> UIImage {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
