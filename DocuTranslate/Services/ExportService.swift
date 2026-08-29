import Foundation
import UIKit
import PDFKit
import Photos

// MARK: - Export Service

class ExportService {
    static let shared = ExportService()
    private init() {}

    /// Folder visible in Files app: On My iPhone → DocuTranslate → Exports
    static let exportsFolderName = "Exports"

    struct SavedExport {
        let fileName: String
        let fileURL: URL?
        let savedToPhotos: Bool
        let userMessage: String
        let detailMessage: String
    }

    // MARK: - Export & Save

    func exportAndSave(
        document: TranslatedDocument,
        as format: ExportFormat,
        scannedImage: UIImage? = nil,
        scannedImages: [UIImage]? = nil
    ) async throws -> SavedExport {
        var pages = scannedImages ?? scannedImage.map { [$0] } ?? []
        if pages.isEmpty {
            pages = renderTextPages(document)
        }
        pages = DocumentBranding.apply(pages, to: document)

        if format.isImage {
            return try await saveImagesToPhotos(pages, format: format, fileName: sanitizedFileName(document.fileName))
        }

        let tempURL = try await export(
            document: document,
            as: format,
            scannedImages: pages
        )
        let saved = try saveDocumentExport(from: tempURL, format: format)
        AppAnalytics.log("document_exported", ["format": format.rawValue, "pages": document.pageCount])
        return saved
    }

    func export(document: TranslatedDocument, as format: ExportFormat, scannedImage: UIImage? = nil, scannedImages: [UIImage]? = nil) async throws -> URL {
        let images = scannedImages ?? scannedImage.map { [$0] }
        let name = sanitizedFileName("\(document.fileName)_\(document.targetLanguage.code)")
        switch format {
        case .pdf:  return try await makePDF(doc: document, images: images, name: name)
        case .docx: return try await makeDOCX(doc: document, name: name)
        case .jpeg: return try await makeJPEG(doc: document, images: images ?? [], name: name)
        case .png:  return try await makePNG(doc: document, images: images ?? [], name: name)
        case .txt:  return try await makeTXT(doc: document, name: name)
        case .xlsx: return try await makeCSV(doc: document, name: name)
        }
    }

    func imagesForSigning(_ document: TranslatedDocument, existing: [UIImage], preferExisting: Bool = false) -> [UIImage] {
        if preferExisting, !existing.isEmpty { return existing }
        let rendered = renderTextPages(document)
        if !document.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !rendered.isEmpty {
            return rendered
        }
        if !existing.isEmpty { return existing }
        return rendered
    }

    // MARK: - Save Destinations

    private func saveDocumentExport(from tempURL: URL, format: ExportFormat) throws -> SavedExport {
        let exportsDir = try exportsDirectory()
        let destination = uniqueURL(
            in: exportsDir,
            name: tempURL.deletingPathExtension().lastPathComponent,
            ext: format.fileExtension
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: tempURL, to: destination)

        let fileName = destination.lastPathComponent
        return SavedExport(
            fileName: fileName,
            fileURL: destination,
            savedToPhotos: false,
            userMessage: "Saved to Files",
            detailMessage: """
            Your document was saved to:

            Files → On My iPhone → DocuTranslate → \(Self.exportsFolderName)

            File: \(fileName)
            """
        )
    }

    private func saveImagesToPhotos(_ images: [UIImage], format: ExportFormat, fileName: String) async throws -> SavedExport {
        guard !images.isEmpty else { throw ExportError.renderFailed }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photoAccessDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? ExportError.saveFailed)
                }
            }
        }

        let count = images.count
        let ext = format.fileExtension
        AppAnalytics.log("document_exported", ["format": format.rawValue, "pages": count])
        return SavedExport(
            fileName: count == 1 ? "\(fileName).\(ext)" : "\(fileName)_page_1-\(count).\(ext)",
            fileURL: nil,
            savedToPhotos: true,
            userMessage: count == 1 ? "Saved to Photos" : "Saved \(count) pages to Photos",
            detailMessage: count == 1
                ? """
                Your image was saved to the Photos app.

                Open the Photos app → Recents to view it.
                """
                : """
                All \(count) pages were saved to the Photos app as separate images.

                Open Photos → Recents to view pages 1 through \(count).
                """
        )
    }

    private func saveImageExport(from tempURL: URL, format: ExportFormat) async throws -> SavedExport {
        guard let data = try? Data(contentsOf: tempURL),
              let image = UIImage(data: data) else {
            throw ExportError.renderFailed
        }
        return try await saveImagesToPhotos([image], format: format, fileName: tempURL.deletingPathExtension().lastPathComponent)
    }

    func exportsDirectory() throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ExportError.saveFailed
        }
        let dir = docs.appendingPathComponent(Self.exportsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func listSavedDocuments() -> [URL] {
        guard let dir = try? exportsDirectory() else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d0 > d1
        }
    }

    // MARK: - PDF

    private func makePDF(doc: TranslatedDocument, images: [UIImage]?, name: String) async throws -> URL {
        let url = tmp(name, "pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { ctx in
            if let images, !images.isEmpty {
                for image in images {
                    ctx.beginPage()
                    let margin: CGFloat = 20
                    let maxW = pageRect.width - margin * 2
                    let maxH = pageRect.height - margin * 2
                    let scale = min(maxW / image.size.width, maxH / image.size.height)
                    let w = image.size.width * scale
                    let h = image.size.height * scale
                    let x = (pageRect.width - w) / 2
                    let y = (pageRect.height - h) / 2
                    image.draw(in: CGRect(x: x, y: y, width: w, height: h))
                }
                return
            }

            ctx.beginPage()
            let style = NSMutableParagraphStyle(); style.lineSpacing = 4
            let bodyAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black, .paragraphStyle: style]
            let pages = doc.translatedPageTexts
            for (index, body) in pages.enumerated() {
                if index > 0 { ctx.beginPage() }
                body.draw(in: CGRect(x: 40, y: 40, width: pageRect.width - 80, height: pageRect.height - 80), withAttributes: bodyAttr)
            }
        }
        try data.write(to: url)
        return url
    }

    // MARK: - DOCX (minimal XML)

    private func makeDOCX(doc: TranslatedDocument, name: String) async throws -> URL {
        let url = tmp(name, "docx")
        let esc = DocumentPageBreak.displayText(doc.translatedText)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        var bodyLines = esc.components(separatedBy: "\n")
        if let footer = DocumentBranding.textFooter(for: doc) {
            let safe = footer
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            bodyLines.append(safe)
        }
        let paras = bodyLines
            .map { "<w:p><w:r><w:t xml:space=\"preserve\">\($0)</w:t></w:r></w:p>" }
            .joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            \(paras)
          </w:body>
        </w:document>
        """
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - JPEG / PNG

    private func makeJPEG(doc: TranslatedDocument, images: [UIImage], name: String) async throws -> URL {
        let pages = images.isEmpty ? renderTextPages(doc) : images
        let url = tmp(name, "jpg")
        guard let first = pages.first, let d = first.jpegData(compressionQuality: 0.92) else { throw ExportError.renderFailed }
        try d.write(to: url)
        return url
    }

    private func makePNG(doc: TranslatedDocument, images: [UIImage], name: String) async throws -> URL {
        let pages = images.isEmpty ? renderTextPages(doc) : images
        let url = tmp(name, "png")
        guard let first = pages.first, let d = first.pngData() else { throw ExportError.renderFailed }
        try d.write(to: url)
        return url
    }

    // MARK: - TXT

    private func makeTXT(doc: TranslatedDocument, name: String) async throws -> URL {
        let url = tmp(name, "txt")
        var content = DocumentPageBreak.displayText(doc.translatedText)
        if let footer = DocumentBranding.textFooter(for: doc) {
            content += "\n\(footer)"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - CSV

    private func makeCSV(doc: TranslatedDocument, name: String) async throws -> URL {
        let url = tmp(name, "csv")
        let orig  = DocumentPageBreak.displayText(doc.originalText).components(separatedBy: "\n")
        let trans = DocumentPageBreak.displayText(doc.translatedText).components(separatedBy: "\n")
        var csv = "Original,Translated\n"
        for i in 0..<max(orig.count, trans.count) {
            let o = i < orig.count  ? orig[i].replacingOccurrences(of: "\"", with: "\"\"") : ""
            let t = i < trans.count ? trans[i].replacingOccurrences(of: "\"", with: "\"\"") : ""
            csv += "\"\(o)\",\"\(t)\"\n"
        }
        if let footer = DocumentBranding.textFooter(for: doc) {
            csv += "\"\",\"\(footer)\"\n"
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    private func renderText(_ doc: TranslatedDocument) -> UIImage {
        renderTextPages(doc).first ?? UIGraphicsImageRenderer(size: CGSize(width: 794, height: 1123)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 794, height: 1123))
        }
    }

    func renderTextPages(_ doc: TranslatedDocument) -> [UIImage] {
        let bodies = doc.translatedPageTexts
        let hasExplicitPages = doc.translatedText.contains(DocumentPageBreak.marker) || bodies.count == max(doc.pageCount, 1)
        if hasExplicitPages, !bodies.isEmpty {
            let total = max(bodies.count, doc.pageCount, 1)
            return (0..<total).map { index in
                let body = index < bodies.count ? bodies[index] : ""
                return renderTextPage(doc, body: body, page: index + 1, total: total)
            }
        }

        let pageCount = max(doc.pageCount, 1)
        let paragraphs = DocumentPageBreak.displayText(doc.translatedText).components(separatedBy: "\n")
        let chunkSize = max(1, Int(ceil(Double(max(paragraphs.count, 1)) / Double(pageCount))))
        var pages: [UIImage] = []
        var index = 0
        var pageIndex = 0
        while index < paragraphs.count || pages.isEmpty {
            let slice = Array(paragraphs[index..<min(index + chunkSize, paragraphs.count)])
            pageIndex += 1
            pages.append(renderTextPage(doc, body: slice.joined(separator: "\n"), page: pageIndex, total: pageCount))
            index += chunkSize
            if index >= paragraphs.count { break }
        }
        return pages.isEmpty ? [renderTextPage(doc, body: DocumentPageBreak.displayText(doc.translatedText), page: 1, total: 1)] : pages
    }

    private func renderTextPage(_ doc: TranslatedDocument, body: String, page: Int, total: Int) -> UIImage {
        let size = CGSize(width: 794, height: 1123)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let bAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.darkText]
            body.draw(in: CGRect(x: 40, y: 40, width: size.width - 80, height: size.height - 80), withAttributes: bAttr)
        }
    }

    private func tmp(_ name: String, _ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(ext)
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    private func uniqueURL(in directory: URL, name: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent(name).appendingPathExtension(ext)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name)_\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}

enum ExportError: LocalizedError {
    case encodingFailed, renderFailed, saveFailed, photoAccessDenied

    var errorDescription: String? {
        switch self {
        case .encodingFailed:     return "Failed to encode document."
        case .renderFailed:       return "Failed to render document image."
        case .saveFailed:         return "Could not save the exported file."
        case .photoAccessDenied:  return "Photo library access is required to save images. Enable it in Settings → DocuTranslate → Photos."
        }
    }
}
