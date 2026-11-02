import UIKit

struct DocumentWatermarkLayout {
    var fontSize: CGFloat
    var banner: CGRect
    var close: CGRect
}

enum DocumentBranding {
    static let tag = "Prepared by DocuTranslate"
    static let angleDegrees: CGFloat = -36

    static func apply(_ images: [UIImage], to document: TranslatedDocument) -> [UIImage] {
        guard document.showsBrandingTag, !images.isEmpty else { return images }
        return images.map(stamp)
    }

    static func layout(for size: CGSize) -> DocumentWatermarkLayout {
        let fontSize = max(16, min(size.width, size.height) * 0.07)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let textWidth = (tag as NSString).size(withAttributes: [.font: font]).width
        let alpha = angleDegrees * .pi / 180
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = textWidth / 2 + fontSize * 0.7
        let end = CGPoint(
            x: center.x + cos(alpha) * reach,
            y: center.y + sin(alpha) * reach
        )
        let side = max(28, fontSize * 0.9)
        let close = CGRect(
            x: min(max(4, end.x - side / 2), max(4, size.width - side - 4)),
            y: min(max(4, end.y - side / 2), max(4, size.height - side - 4)),
            width: side,
            height: side
        )
        let banner = CGRect(
            x: size.width * 0.08,
            y: size.height * 0.28,
            width: size.width * 0.84,
            height: size.height * 0.44
        )
        return DocumentWatermarkLayout(fontSize: fontSize, banner: banner, close: close)
    }

    static func fontSize(for canvasSize: CGSize) -> CGFloat {
        layout(for: canvasSize).fontSize
    }

    static func bottomInset(for size: CGSize) -> CGFloat {
        _ = size
        return 0
    }

    static func stamp(_ image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let layout = layout(for: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            image.draw(in: CGRect(origin: .zero, size: size))
            drawDiagonalMarks(in: renderer.cgContext, size: size, fontSize: layout.fontSize)
            drawCloseMark(in: layout.close)
        }
    }

    private static func drawDiagonalMarks(in context: CGContext, size: CGSize, fontSize: CGFloat) {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let text = tag as NSString
        let textSize = text.size(withAttributes: [.font: font])
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angleDegrees * .pi / 180)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.white.withAlphaComponent(0.85)
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        shadow.shadowBlurRadius = 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black.withAlphaComponent(0.2),
            .shadow: shadow
        ]
        text.draw(
            at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2),
            withAttributes: attributes
        )
        context.restoreGState()
    }

    private static func drawCloseMark(in rect: CGRect) {
        let circle = UIBezierPath(ovalIn: rect)
        UIColor.systemRed.setFill()
        circle.fill()
        UIColor.white.setStroke()
        let mark = UIBezierPath()
        let inset = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)
        mark.move(to: CGPoint(x: inset.minX, y: inset.minY))
        mark.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
        mark.move(to: CGPoint(x: inset.maxX, y: inset.minY))
        mark.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
        mark.lineWidth = max(2, rect.width * 0.1)
        mark.lineCapStyle = .round
        mark.stroke()
    }

    static func textFooter(for document: TranslatedDocument) -> String? {
        document.showsBrandingTag ? tag : nil
    }
}
