import SwiftUI
import PhotosUI

@MainActor
class ConvertViewModel: ObservableObject {
    @Published var selectedFileURL: URL?
    @Published var selectedFileName: String?
    @Published var pages: [UIImage] = []
    @Published var extractedText = ""
    @Published var documentType: DocumentType = .pdf
    @Published var pageCount = 1
    @Published var fileSize = "—"
    @Published var outputFormat: ExportFormat = .pdf

    @Published var isProcessing = false
    @Published var processedDocument: TranslatedDocument?

    @Published var showFilePicker = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var photoItems: [PhotosPickerItem] = []

    private let processor = DocumentProcessor.shared

    var hasSource: Bool {
        selectedFileURL != nil || !pages.isEmpty
    }

    func reset() {
        selectedFileURL = nil
        selectedFileName = nil
        pages = []
        extractedText = ""
        documentType = .pdf
        pageCount = 1
        fileSize = "—"
        processedDocument = nil
        photoItems = []
    }

    func loadFile(url: URL) async {
        reset()
        selectedFileURL = url
        selectedFileName = url.deletingPathExtension().lastPathComponent
        fileSize = processor.formattedFileSize(url: url)
        pages = processor.renderPages(from: url)
        pageCount = max(pages.count, 1)
        do {
            let extracted = try await processor.extractText(from: url)
            extractedText = extracted.text
            documentType = extracted.type
            pageCount = max(extracted.pageCount, pages.count, 1)
        } catch {
            if pages.isEmpty {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        suggestOutputFormat()
    }

    func loadPhotos() async {
        var images: [UIImage] = []
        for item in photoItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        photoItems = []
        guard !images.isEmpty else { return }
        reset()
        pages = images
        pageCount = images.count
        selectedFileName = images.count == 1 ? "Photo" : "Photos"
        documentType = .image
        extractedText = (try? await processor.extractText(from: images[0])) ?? ""
        suggestOutputFormat()
    }

    func convert() async {
        guard hasSource else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            if extractedText.isEmpty, let url = selectedFileURL {
                let extracted = try await processor.extractText(from: url)
                extractedText = extracted.text
                documentType = extracted.type
                pageCount = max(extracted.pageCount, pages.count, 1)
            }

            if pages.isEmpty, !extractedText.isEmpty {
                let draft = makeDocument()
                pages = ExportService.shared.renderTextPages(draft)
                pageCount = max(pages.count, 1)
            }

            guard !pages.isEmpty || !extractedText.isEmpty else {
                throw TranslationError.extractionFailed
            }

            let doc = makeDocument()
            processedDocument = doc
            AppAnalytics.log("document_converted", [
                "format": outputFormat.rawValue,
                "pages": pageCount,
                "type": documentType.rawValue
            ])
            ReviewPromptService.shared.considerPrompt(after: "convert")
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func makeDocument() -> TranslatedDocument {
        TranslatedDocument(
            fileName: selectedFileName ?? "Converted_Document",
            originalLanguage: Language.english,
            targetLanguage: Language.english,
            documentType: documentType,
            translatedText: extractedText,
            originalText: extractedText,
            pageCount: max(pageCount, pages.count, 1),
            fileSize: fileSize,
            wasConverted: true
        )
    }

    private func suggestOutputFormat() {
        switch documentType {
        case .pdf: outputFormat = .docx
        case .word, .text: outputFormat = .pdf
        case .excel: outputFormat = .pdf
        case .image, .scanned: outputFormat = .pdf
        case .powerPoint: outputFormat = .pdf
        }
    }
}
