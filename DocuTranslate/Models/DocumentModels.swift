import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - Document Type

enum DocumentType: String, CaseIterable, Codable {
    case pdf       = "PDF"
    case word      = "Word (.docx)"
    case image     = "Image"
    case text      = "Text (.txt)"
    case excel     = "Excel (.xlsx)"
    case powerPoint = "PowerPoint (.pptx)"
    case scanned   = "Scanned"

    var icon: String {
        switch self {
        case .pdf:         return "doc.fill"
        case .word:        return "doc.text.fill"
        case .image:       return "photo.fill"
        case .text:        return "doc.plaintext.fill"
        case .excel:       return "tablecells.fill"
        case .powerPoint:  return "rectangle.on.rectangle.fill"
        case .scanned:     return "scanner.fill"
        }
    }

    var color: String {
        switch self {
        case .pdf:         return "#E74C3C"
        case .word:        return "#2980B9"
        case .image:       return "#27AE60"
        case .text:        return "#7F8C8D"
        case .excel:       return "#1A7A4A"
        case .powerPoint:  return "#D35400"
        case .scanned:     return "#8E44AD"
        }
    }

    var utType: UTType {
        switch self {
        case .pdf:         return .pdf
        case .word:        return UTType(filenameExtension: "docx") ?? .data
        case .image:       return .image
        case .text:        return .plainText
        case .excel:       return UTType(filenameExtension: "xlsx") ?? .data
        case .powerPoint:  return UTType(filenameExtension: "pptx") ?? .data
        case .scanned:     return .image
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf:         return "pdf"
        case .word:        return "docx"
        case .image:       return "jpg"
        case .text:        return "txt"
        case .excel:       return "xlsx"
        case .powerPoint:  return "pptx"
        case .scanned:     return "jpg"
        }
    }
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf        = "PDF"
    case docx       = "Word (.docx)"
    case jpeg       = "JPEG Image"
    case png        = "PNG Image"
    case txt        = "Plain Text"
    case xlsx       = "Excel (.xlsx)"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pdf:  return "doc.fill"
        case .docx: return "doc.text.fill"
        case .jpeg: return "photo.fill"
        case .png:  return "photo.on.rectangle.fill"
        case .txt:  return "doc.plaintext.fill"
        case .xlsx: return "tablecells.fill"
        }
    }

    var mimeType: String {
        switch self {
        case .pdf:  return "application/pdf"
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .jpeg: return "image/jpeg"
        case .png:  return "image/png"
        case .txt:  return "text/plain"
        case .xlsx: return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf:  return "pdf"
        case .docx: return "docx"
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .txt:  return "txt"
        case .xlsx: return "xlsx"
        }
    }

    var isImage: Bool {
        switch self {
        case .jpeg, .png: return true
        default: return false
        }
    }
}

// MARK: - Scan Filter

enum ScanFilter: String, CaseIterable, Identifiable {
    case none         = "Original"
    case document     = "Document"
    case highContrast = "High Contrast"
    case textBoost    = "Text Boost"
    case cleanScan    = "Clean Scan"
    case sharpPlus    = "Sharp+"
    case enhanced     = "Enhanced"
    case scan         = "Scanner"
    case magicColor   = "Magic Color"
    case blackWhite   = "Black & White"
    case bw2          = "B&W 2"
    case grayscale    = "Grayscale"
    case color        = "Color"
    case photo        = "Photo"
    case fadedInk     = "Faded Ink"
    case softLight    = "Soft Light"
    case denoise      = "Denoise"
    case inkSaver     = "Ink Saver"
    case magazine     = "Magazine"
    case vivid        = "Vivid"
    case newspaper    = "Newspaper"
    case nostalgic    = "Nostalgic"
    case warmTone     = "Warm Tone"
    case coolTone     = "Cool Tone"
    case aged         = "Aged Paper"
    case invert       = "Invert"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .none:         return "circle.lefthalf.filled"
        case .document:     return "doc.text.viewfinder"
        case .highContrast: return "circle.lefthalf.striped.horizontal"
        case .textBoost:    return "textformat.size.larger"
        case .cleanScan:    return "wand.and.rays"
        case .sharpPlus:    return "scope"
        case .enhanced:     return "sparkles"
        case .scan:         return "scanner.fill"
        case .magicColor:   return "wand.and.stars"
        case .blackWhite:   return "circle.fill"
        case .bw2:          return "circle.lefthalf.filled.inverse"
        case .grayscale:    return "circle.dotted"
        case .color:        return "paintbrush.fill"
        case .photo:        return "camera.fill"
        case .fadedInk:     return "pencil.line"
        case .softLight:    return "sun.max.fill"
        case .denoise:      return "aqi.medium"
        case .inkSaver:     return "drop.fill"
        case .magazine:     return "book.pages.fill"
        case .vivid:        return "paintpalette.fill"
        case .newspaper:    return "newspaper.fill"
        case .nostalgic:    return "photo.artframe"
        case .warmTone:     return "sun.horizon.fill"
        case .coolTone:     return "snowflake"
        case .aged:         return "scroll.fill"
        case .invert:       return "arrow.triangle.2.circlepath"
        }
    }

    var subtitle: String {
        switch self {
        case .none:         return "No filter"
        case .document:     return "Best for text"
        case .highContrast: return "Max clarity"
        case .textBoost:    return "OCR ready"
        case .cleanScan:    return "Remove tint"
        case .sharpPlus:    return "Extra sharp"
        case .enhanced:     return "Balanced"
        case .scan:         return "Classic scan"
        case .magicColor:   return "Auto fix"
        case .blackWhite:   return "Pure B&W"
        case .bw2:          return "Ultra contrast"
        case .grayscale:    return "Soft gray"
        case .color:        return "Natural color"
        case .photo:        return "Keep photo look"
        case .fadedInk:     return "Faint text"
        case .softLight:    return "Fix shadows"
        case .denoise:      return "Reduce blur"
        case .inkSaver:     return "Print friendly"
        case .magazine:     return "Color pages"
        case .vivid:        return "Rich colors"
        case .newspaper:    return "Newsprint"
        case .nostalgic:    return "Sepia tone"
        case .warmTone:     return "Fix blue tint"
        case .coolTone:     return "Fix yellow"
        case .aged:         return "Vintage"
        case .invert:       return "Dark pages"
        }
    }

    var accentHex: String {
        switch self {
        case .none:         return "#8E8E93"
        case .document:     return "#1a56d6"
        case .highContrast: return "#111827"
        case .textBoost:    return "#059669"
        case .cleanScan:    return "#0891B2"
        case .sharpPlus:    return "#7C3AED"
        case .enhanced:     return "#2563EB"
        case .scan:         return "#0D9488"
        case .magicColor:   return "#E11D48"
        case .blackWhite:   return "#374151"
        case .bw2:          return "#1F2937"
        case .grayscale:    return "#6B7280"
        case .color:        return "#3B82F6"
        case .photo:        return "#6366F1"
        case .fadedInk:     return "#92400E"
        case .softLight:    return "#F59E0B"
        case .denoise:      return "#14B8A6"
        case .inkSaver:     return "#64748B"
        case .magazine:     return "#DB2777"
        case .vivid:        return "#EA580C"
        case .newspaper:    return "#4B5563"
        case .nostalgic:    return "#B45309"
        case .warmTone:     return "#F97316"
        case .coolTone:     return "#0284C7"
        case .aged:         return "#A16207"
        case .invert:       return "#581C87"
        }
    }

    /// Clarity-first filters shown first in the scroll list.
    static var clarityFirst: [ScanFilter] {
        [.document, .highContrast, .textBoost, .cleanScan, .sharpPlus, .enhanced, .scan,
         .magicColor, .denoise, .fadedInk, .softLight, .warmTone, .coolTone,
         .blackWhite, .bw2, .grayscale, .inkSaver,
         .color, .photo, .magazine, .vivid, .newspaper, .nostalgic, .aged, .invert, .none]
    }
}

// MARK: - Scan Editor Tool

enum ScanEditorTab: String, CaseIterable, Identifiable {
    case adjust = "Adjust"
    case filters = "Filters"
    case rotate = "Rotate"
    case delete = "Delete"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .adjust:  return "crop"
        case .filters: return "camera.filters"
        case .rotate:  return "rotate.right"
        case .delete:  return "trash"
        }
    }
}

// MARK: - Page breaks (kept through translation so every page stays distinct)

enum DocumentPageBreak {
    static let marker = "<<<DT_PAGE>>>"

    static func join(_ pages: [String]) -> String {
        guard pages.count > 1 else { return pages.first ?? "" }
        return pages.joined(separator: "\n\(marker)\n")
    }

    static func split(_ text: String) -> [String] {
        guard text.contains(marker) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [text]
        }
        return text.components(separatedBy: marker).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func displayText(_ text: String) -> String {
        let pages = split(text)
        return pages.isEmpty ? text : pages.joined(separator: "\n\n")
    }
}

// MARK: - Translated Document

struct TranslatedDocument: Identifiable, Codable {
    var id: UUID = UUID()
    var fileName: String
    var originalLanguage: Language
    var targetLanguage: Language
    var documentType: DocumentType
    var translatedText: String
    var originalText: String
    var createdAt: Date = Date()
    var thumbnailData: Data?
    var isFavorite: Bool = false
    var pageCount: Int = 1
    var fileSize: String = "—"
    var pageImageFileNames: [String]? = nil
    var wasSigned: Bool? = nil
    var wasConverted: Bool? = nil
    var brandingRemoved: Bool? = nil

    var thumbnail: UIImage? {
        thumbnailData.flatMap { UIImage(data: $0) }
    }

    /// Converted, signed/stamped, and scanned files carry a small footer tag unless the user paid to remove it.
    var showsBrandingTag: Bool {
        if brandingRemoved == true { return false }
        if BrandingStore.hasRemovedTag(for: id) { return false }
        return wasSigned == true || wasConverted == true || documentType == .scanned
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    var translatedPageTexts: [String] {
        let pages = DocumentPageBreak.split(translatedText)
        return pages.isEmpty ? [translatedText] : pages
    }

    var originalPageTexts: [String] {
        let pages = DocumentPageBreak.split(originalText)
        return pages.isEmpty ? [originalText] : pages
    }
}

// MARK: - Scan Session

struct ScanSession: Identifiable {
    var id: UUID = UUID()
    var pages: [ScannedPage] = []
    var filter: ScanFilter = .document
    var perspectiveCorrected: Bool = true
    var autoEnhance: Bool = true
    var sharpness: Double = 0.65
    var brightness: Double = 0.0
    var contrast: Double = 0.0
}

struct ScannedPage: Identifiable {
    var id: UUID = UUID()
    var originalImage: UIImage
    var baseImage: UIImage?
    var processedImage: UIImage?
    var cropRect: CGRect?
    var rotation: Double = 0
    var extractedText: String = ""
    var wasEnhanced: Bool = false

    var displayImage: UIImage { processedImage ?? baseImage ?? originalImage }
}

// MARK: - Translation Progress

enum TranslationStep: String, CaseIterable {
    case uploading   = "Reading document"
    case extracting  = "Extracting text"
    case detecting   = "Detecting language"
    case translating = "Translating content"
    case formatting  = "Applying formatting"
    case rendering   = "Rendering document"
    case complete    = "Complete"

    var progress: Double {
        switch self {
        case .uploading:   return 0.10
        case .extracting:  return 0.25
        case .detecting:   return 0.35
        case .translating: return 0.65
        case .formatting:  return 0.80
        case .rendering:   return 0.95
        case .complete:    return 1.00
        }
    }
}
