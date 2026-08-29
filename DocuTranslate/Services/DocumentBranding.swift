import UIKit

enum DocumentBranding {
    static let tag = "Scanned by DocuTranslate"

    static func apply(_ images: [UIImage], to document: TranslatedDocument) -> [UIImage] {
        guard document.showsBrandingTag, !images.isEmpty else { return images }
        return images.map(stamp)
    }

    static func fontSize(for canvasSize: CGSize) -> CGFloat {
        max(10, min(canvasSize.width * 0.022, 16))
    }

    static func stamp(_ image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))

            let fontSize = fontSize(for: size)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let textSize = (tag as NSString).size(withAttributes: attributes)
            let padX: CGFloat = 8
            let padY: CGFloat = 5
            let box = CGRect(
                x: size.width - textSize.width - padX * 2 - size.width * 0.03,
                y: size.height - textSize.height - padY * 2 - size.height * 0.02,
                width: textSize.width + padX * 2,
                height: textSize.height + padY * 2
            )
            let path = UIBezierPath(roundedRect: box, cornerRadius: 4)
            UIColor.black.withAlphaComponent(0.45).setFill()
            path.fill()
            (tag as NSString).draw(
                at: CGPoint(x: box.minX + padX, y: box.minY + padY),
                withAttributes: attributes
            )
        }
    }

    static func textFooter(for document: TranslatedDocument) -> String? {
        document.showsBrandingTag ? tag : nil
    }
}
