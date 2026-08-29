import Foundation
import UIKit
import PDFKit
import Vision
import UniformTypeIdentifiers

// MARK: - Document Processor

class DocumentProcessor {
    static let shared = DocumentProcessor()
    private init() {}

    // MARK: - Extract text from URL

    func extractText(from url: URL) async throws -> (text: String, pageCount: Int, type: DocumentType) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            let result = try await extractFromPDF(url: url)
            return (result.text, result.pages, .pdf)
        case "docx", "doc":
            return (try await extractFromOfficeXML(url: url), 1, .word)
        case "txt", "md", "rtf":
            let text = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                    ?? ""
            return (text, 1, .text)
        case "jpg", "jpeg", "png", "heic", "bmp", "tiff", "gif", "webp":
            return (try await extractFromImage(url: url), 1, .image)
        case "xlsx", "xls":
            return (try await extractFromOfficeXML(url: url), 1, .excel)
        case "csv":
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return (text, 1, .excel)
        case "pptx", "ppt":
            return (try await extractFromOfficeXML(url: url), 1, .powerPoint)
        default:
            // Generic text attempt
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return (text, 1, .text)
            }
            throw TranslationError.extractionFailed
        }
    }

    func extractText(from image: UIImage) async throws -> String {
        try await performOCR(on: image)
    }

    func renderPages(from url: URL) -> [UIImage] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { return [] }
            return (0..<pdf.pageCount).compactMap { index in
                guard let page = pdf.page(at: index) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2
                let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
                return page.thumbnail(of: size, for: .mediaBox)
            }
        case "jpg", "jpeg", "png", "heic", "bmp", "tiff", "gif", "webp":
            if let image = UIImage(contentsOfFile: url.path) { return [image] }
            return []
        default:
            return []
        }
    }

    // MARK: - PDF

    private func extractFromPDF(url: URL) async throws -> (text: String, pages: Int) {
        guard let pdf = PDFDocument(url: url) else { throw TranslationError.extractionFailed }
        let count = pdf.pageCount
        var full = ""
        for i in 0..<count {
            guard let page = pdf.page(at: i) else { continue }
            if let native = page.string, !native.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                full += native + "\n\n"
            } else if let img = renderPage(page) {
                let ocr = (try? await performOCR(on: img)) ?? ""
                full += ocr + "\n\n"
            }
        }
        if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw TranslationError.extractionFailed }
        return (full, count)
    }

    private func renderPage(_ page: PDFPage) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img
    }

    // MARK: - Office XML (docx / xlsx / pptx)

    private func extractFromOfficeXML(url: URL) async throws -> String {
        // docx/xlsx/pptx are ZIP archives containing XML.
        // We do a best-effort text extraction by reading the raw bytes and stripping XML tags.
        guard let data = try? Data(contentsOf: url) else { throw TranslationError.extractionFailed }
        // Try UTF-8 decode (works for plain text fallback)
        if let raw = String(data: data, encoding: .utf8) {
            return stripXMLTags(raw)
        }
        // Binary — attempt to find readable text segments
        let ascii = String(data.compactMap { $0 > 31 && $0 < 127 ? Character(UnicodeScalar($0)) : nil })
        let stripped = stripXMLTags(ascii)
        if stripped.count > 20 { return stripped }
        throw TranslationError.extractionFailed
    }

    private func stripXMLTags(_ xml: String) -> String {
        var result = xml
        // Remove XML/HTML tags via simple pass
        var inTag = false
        var clean = ""
        for ch in result {
            if ch == "<" { inTag = true }
            else if ch == ">" { inTag = false }
            else if !inTag { clean.append(ch) }
        }
        // Collapse whitespace
        return clean
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Image OCR

    private func extractFromImage(url: URL) async throws -> String {
        guard let img = UIImage(contentsOfFile: url.path) else { throw TranslationError.invalidImage }
        return try await performOCR(on: img)
    }

    private func performOCR(on image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { throw TranslationError.invalidImage }
        return try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { r, err in
                if let err = err { cont.resume(throwing: err); return }
                let text = (r.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                cont.resume(returning: text)
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.automaticallyDetectsLanguage = true
            req.minimumTextHeight = 0.01
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
        }
    }

    // MARK: - File Size

    func formattedFileSize(url: URL) -> String {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attr[.size] as? Int else { return "—" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: Int64(size))
    }
}
