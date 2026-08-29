import SwiftUI
import PhotosUI
import VisionKit

@MainActor
class ScanViewModel: ObservableObject {
    @Published var session = ScanSession()
    @Published var currentPageIndex: Int? = nil

    @Published var showScanner = false
    @Published var showPhotoPicker = false
    @Published var showFilePicker = false
    @Published var showCropEditor = false
    @Published var showTranslateSheet = false
    @Published var showSignStampEditor = false
    @Published var showExportOptions = false
    @Published var showActionSheet = false
    @Published var showExportError = false
    @Published var exportErrorMessage = ""

    @Published var editingPageIndex: Int?
    @Published var photoPickerItems: [PhotosPickerItem] = []
    @Published var editorTab: ScanEditorTab = .filters

    private let scanner = ScannerService.shared
    private let proc = DocumentProcessor.shared

    // MARK: - Add pages

    func addPage(image: UIImage) async {
        var page = ScannedPage(originalImage: image)
        var base = image

        if session.perspectiveCorrected, let corners = await scanner.detectDocumentBounds(in: image) {
            base = scanner.applyPerspectiveCorrection(to: image, corners: corners)
        }

        page.baseImage = base
        page.processedImage = processImage(base)
        page.wasEnhanced = session.autoEnhance
        session.pages.append(page)
        currentPageIndex = session.pages.count - 1
        AppAnalytics.log("document_scanned", ["page_count": session.pages.count])
        persistToHistory(signed: false)
    }

    func addFromFile(url: URL) async {
        if url.pathExtension.lowercased() == "pdf",
           let pdf = CGPDFDocument(url as CFURL) {
            for i in 1...max(1, pdf.numberOfPages) {
                if let p = pdf.page(at: i) { await addPage(image: renderPDF(p)) }
            }
        } else if let img = UIImage(contentsOfFile: url.path) {
            await addPage(image: img)
        }
    }

    func loadPhotos(from items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                await addPage(image: img)
            }
        }
        photoPickerItems = []
    }

    // MARK: - Page ops

    func deletePage(at idx: Int) {
        guard idx < session.pages.count else { return }
        session.pages.remove(at: idx)
        currentPageIndex = session.pages.isEmpty ? nil : max(0, min(idx, session.pages.count - 1))
    }

    func rotatePage(at idx: Int) {
        guard idx < session.pages.count else { return }
        let base = session.pages[idx].displayImage
        let rotated = scanner.rotate(image: base, degrees: 90)
        session.pages[idx].baseImage = rotated
        session.pages[idx].processedImage = processImage(rotated)
    }

    func cropPage(at idx: Int, rect: CGRect) {
        guard idx < session.pages.count else { return }
        let base = session.pages[idx].displayImage
        let cropped = scanner.crop(image: base, to: rect)
        session.pages[idx].baseImage = cropped
        session.pages[idx].processedImage = processImage(cropped)
        session.pages[idx].cropRect = rect
    }

    func enhanceCurrentPage() {
        guard let idx = currentPageIndex, idx < session.pages.count else { return }
        let base = session.pages[idx].baseImage ?? session.pages[idx].originalImage
        session.pages[idx].processedImage = processImage(base, forceEnhance: true)
        session.pages[idx].wasEnhanced = true
    }

    func toggleBeforeAfter() {
        guard let idx = currentPageIndex, idx < session.pages.count else { return }
        let page = session.pages[idx]
        if page.processedImage != nil {
            session.pages[idx].processedImage = nil
        } else if let base = page.baseImage {
            session.pages[idx].processedImage = processImage(base)
        }
    }

    // MARK: - Sign & Stamp

    func applySignAndStamp(to indices: [Int], signature: PlacedOverlay?, stamp: PlacedOverlay?) {
        let service = SignStampService.shared
        for idx in indices where idx < session.pages.count {
            let base = session.pages[idx].displayImage
            session.pages[idx].processedImage = service.composite(
                base: base,
                signature: signature,
                stamp: stamp
            )
        }
    }

    // MARK: - Filters

    func applyFilter(_ filter: ScanFilter) {
        session.filter = filter
        reapplyFilter()
    }

    func reapplyFilter() {
        for i in 0..<session.pages.count {
            let base = session.pages[i].baseImage ?? session.pages[i].originalImage
            session.pages[i].processedImage = processImage(base)
        }
    }

    private func processImage(_ image: UIImage, forceEnhance: Bool = false) -> UIImage {
        var result = image
        if session.autoEnhance || forceEnhance {
            result = scanner.enhanceDocument(result, strength: session.sharpness)
        }
        return scanner.applyFilter(
            session.filter,
            to: result,
            brightness: session.brightness,
            contrast: session.contrast
        )
    }

    // MARK: - OCR

    func extractAllText() async -> String {
        var all = ""
        for page in session.pages {
            if let text = try? await proc.extractText(from: page.displayImage), !text.isEmpty {
                all += text + "\n\n"
            }
        }
        return all
    }

    // MARK: - Export

    func export(as format: ExportFormat) async -> (TranslatedDocument, ExportService.SavedExport)? {
        let images = session.pages.map(\.displayImage)
        let doc = TranslatedDocument(
            id: session.id,
            fileName: "Scanned_Document",
            originalLanguage: Language.all.first(where: { $0.id == "en" })!,
            targetLanguage: Language.all.first(where: { $0.id == "en" })!,
            documentType: .scanned,
            translatedText: await extractAllText(),
            originalText: "",
            pageCount: session.pages.count
        )
        do {
            let result = try await ExportService.shared.exportAndSave(
                document: doc,
                as: format,
                scannedImages: images
            )
            HistoryStore.shared.add(doc, images: images, signed: false)
            ReviewPromptService.shared.considerPrompt(after: "scan_export")
            return (doc, result)
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
            return nil
        }
    }

    func persistToHistory(signed: Bool, images: [UIImage]? = nil) {
        let pages = images ?? session.pages.map(\.displayImage)
        guard !pages.isEmpty else { return }
        let english = Language.all.first { $0.id == "en" } ?? Language.all[0]
        let doc = TranslatedDocument(
            id: session.id,
            fileName: signed ? "Signed_Document" : "Scanned_Document",
            originalLanguage: english,
            targetLanguage: english,
            documentType: .scanned,
            translatedText: "",
            originalText: "",
            pageCount: pages.count
        )
        HistoryStore.shared.add(doc, images: pages, signed: signed)
    }

    func clearSession() { session = ScanSession(); currentPageIndex = nil }

    // MARK: - PDF render helper

    private func renderPDF(_ page: CGPDFPage) -> UIImage {
        let r = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2.0
        let size = CGSize(width: r.width * scale, height: r.height * scale)
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: r.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.drawPDFPage(page)
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }
}
