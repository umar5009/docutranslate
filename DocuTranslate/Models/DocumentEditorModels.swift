import SwiftUI
import UIKit

enum DocumentEditorMode: String, CaseIterable, Identifiable {
    case edit = "Edit"
    case markup = "Highlight"

    var id: String { rawValue }
}

enum EditTool: String, CaseIterable, Identifiable {
    case select, text, image, shape, link, redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .text: return "Text"
        case .image: return "Image"
        case .shape: return "Shape"
        case .link: return "Link"
        case .redact: return "Redact"
        }
    }

    var icon: String {
        switch self {
        case .select: return "arrow.up.left"
        case .text: return "textformat.abc"
        case .image: return "photo"
        case .shape: return "square.on.circle"
        case .link: return "link"
        case .redact: return "xmark.rectangle"
        }
    }
}

enum MarkupTool: String, CaseIterable, Identifiable {
    case highlight, underline, strike, pen, marker, eraser

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var icon: String {
        switch self {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strike: return "strikethrough"
        case .pen: return "pencil.tip"
        case .marker: return "paintbrush.pointed"
        case .eraser: return "eraser"
        }
    }

    var isTextMarkup: Bool {
        switch self {
        case .highlight, .underline, .strike: return true
        default: return false
        }
    }
}

enum EditorShapeKind: String, CaseIterable, Identifiable {
    case rectangle, ellipse, line, arrow

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .line: return "minus"
        case .arrow: return "arrow.up.right"
        }
    }
}

enum EditorElementKind: String {
    case existingText
    case addedText
    case image
    case shape
    case link
    case redact
    case highlight
    case underline
    case strike
    case ink
}

struct EditorElement: Identifiable, Equatable {
    let id: UUID
    var pageIndex: Int
    var kind: EditorElementKind
    var rect: CGRect
    var rotation: Double = 0
    var zIndex: Int

    var text: String = ""
    var originalText: String = ""
    var fontName: String = "Helvetica"
    var fontSize: CGFloat = 0.04
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var alignment: Int = 0
    var colorHex: String = "#111111"
    var isModified = false

    var imageData: Data?
    var shapeKind: EditorShapeKind = .rectangle
    var fillHex: String?
    var lineWidth: CGFloat = 0.004
    var url: String = ""
    var sourceID: UUID?
    var points: [CGPoint] = []
    var inkWidth: CGFloat = 0.01
    var inkOpacity: CGFloat = 1

    var isText: Bool {
        kind == .existingText || kind == .addedText
    }

    var isMarkup: Bool {
        switch kind {
        case .highlight, .underline, .strike, .ink: return true
        default: return false
        }
    }

    var changeLabel: String? {
        switch kind {
        case .existingText where isModified:
            return text.isEmpty ? "Removed Text" : "Replaced Text"
        case .addedText: return "Added Text"
        case .image: return "Added Image"
        case .shape: return "Added Shape"
        case .link: return "Added Link"
        case .redact: return "Redaction"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strike: return "Strikethrough"
        case .ink: return "Drawing"
        default: return nil
        }
    }

    var changeDetail: String {
        switch kind {
        case .existingText, .addedText: return text.isEmpty ? originalText : text
        case .link: return url
        default: return kind.rawValue
        }
    }

    static func existingText(page: Int, rect: CGRect, text: String, zIndex: Int) -> EditorElement {
        EditorElement(
            id: UUID(),
            pageIndex: page,
            kind: .existingText,
            rect: rect,
            zIndex: zIndex,
            text: text,
            originalText: text,
            fontSize: max(0.012, rect.height * 0.82)
        )
    }

    static func addedText(page: Int, rect: CGRect, zIndex: Int, text: String = "", fontSize: CGFloat? = nil, sourceID: UUID? = nil) -> EditorElement {
        EditorElement(
            id: UUID(),
            pageIndex: page,
            kind: .addedText,
            rect: rect,
            zIndex: zIndex,
            text: text,
            originalText: "",
            fontSize: fontSize ?? max(0.018, rect.height * 0.7),
            isModified: true,
            sourceID: sourceID
        )
    }

    static func markup(kind: EditorElementKind, page: Int, rect: CGRect, color: String, zIndex: Int) -> EditorElement {
        EditorElement(
            id: UUID(),
            pageIndex: page,
            kind: kind,
            rect: rect,
            zIndex: zIndex,
            colorHex: color
        )
    }
}

enum DocumentEditorPalette {
    static let accent = Color(hex: "#FF375F")
    static let toolSelected = Color(hex: "#FF375F")

    static let editColors = ["#111111", "#FFFFFF", "#6B7280", "#DC2626", "#2563EB", "#16A34A"]
    static let markupColors = ["#F5D76E", "#A8E6A1", "#7FDBDA", "#E8A0E8", "#F5C4A1", "#F97316", "#EF4444"]
    static let fonts = [
        "Helvetica",
        "Helvetica Neue",
        "Times New Roman",
        "Georgia",
        "Courier New",
        "Avenir Next",
        "Palatino",
        "Menlo",
        "Avenir"
    ]
}

enum FormFieldKind: String {
    case text
    case date
    case signature
    case checkbox

    var title: String {
        switch self {
        case .text: return "Text"
        case .date: return "Date"
        case .signature: return "Signature"
        case .checkbox: return "Checkbox"
        }
    }

    var icon: String {
        switch self {
        case .text: return "text.cursor"
        case .date: return "calendar"
        case .signature: return "signature"
        case .checkbox: return "checkmark.square"
        }
    }
}

struct DetectedFormField: Identifiable, Equatable {
    let id: UUID
    var pageIndex: Int
    var kind: FormFieldKind
    var label: String
    var rect: CGRect
    var labelRect: CGRect
}

struct OCRTextBlock {
    var text: String
    var rect: CGRect
}

struct EditorConnector {
    var start: CGPoint
    var control: CGPoint
    var end: CGPoint

    static func between(source: CGRect, target: CGRect) -> EditorConnector {
        let starts = [
            CGPoint(x: source.midX, y: source.minY),
            CGPoint(x: source.midX, y: source.maxY),
            CGPoint(x: source.minX, y: source.midY),
            CGPoint(x: source.maxX, y: source.midY)
        ]
        let ends = [
            CGPoint(x: target.midX, y: target.minY),
            CGPoint(x: target.midX, y: target.maxY),
            CGPoint(x: target.minX, y: target.midY),
            CGPoint(x: target.maxX, y: target.midY)
        ]
        var start = starts[3]
        var end = ends[2]
        var best = CGFloat.greatestFiniteMagnitude
        for a in starts {
            for b in ends {
                let d = hypot(a.x - b.x, a.y - b.y)
                if d < best {
                    best = d
                    start = a
                    end = b
                }
            }
        }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 1)
        let bend = min(max(length * 0.22, 12), 56)
        let control = CGPoint(
            x: (start.x + end.x) / 2 - dy / length * bend,
            y: (start.y + end.y) / 2 + dx / length * bend
        )
        return EditorConnector(start: start, control: control, end: end)
    }

    func headPoints(length: CGFloat) -> (CGPoint, CGPoint) {
        let angle = atan2(end.y - control.y, end.x - control.x)
        return (
            CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)),
            CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6))
        )
    }
}

extension CGRect {
    func clampedNormalized() -> CGRect {
        var r = self
        r.origin.x = min(max(r.origin.x, 0), 1)
        r.origin.y = min(max(r.origin.y, 0), 1)
        r.size.width = min(max(r.size.width, 0.004), 1 - r.origin.x)
        r.size.height = min(max(r.size.height, 0.004), 1 - r.origin.y)
        return r
    }

    func pixelRect(in size: CGSize) -> CGRect {
        CGRect(
            x: minX * size.width,
            y: minY * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }

    static func normalized(from pixel: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(
            x: pixel.minX / size.width,
            y: pixel.minY / size.height,
            width: pixel.width / size.width,
            height: pixel.height / size.height
        ).clampedNormalized()
    }
}

extension UIColor {
    convenience init(editorHex: String) {
        let hex = editorHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 17, 17, 17)
        }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

func editorUIFont(name: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
    var font = UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
    var traits = font.fontDescriptor.symbolicTraits
    if bold { traits.insert(.traitBold) }
    if italic { traits.insert(.traitItalic) }
    if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
        font = UIFont(descriptor: descriptor, size: size)
    }
    return font
}
