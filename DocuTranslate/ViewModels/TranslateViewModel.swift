import SwiftUI
import UniformTypeIdentifiers

@MainActor
class TranslateViewModel: ObservableObject {
    @Published var sourceLanguage: Language = Language.english
    @Published var targetLanguage: Language = Language.preferredTarget
    @Published var autoDetect: Bool = true

    @Published var selectedFileURL: URL?
    @Published var selectedFileName: String?
    @Published var inputText: String = ""
    @Published var showTextInput: Bool = false

    @Published var isTranslating = false
    @Published var translationProgress: Double = 0
    @Published var currentStep: TranslationStep = .uploading

    @Published var translationResult: TranslatedDocument?
    @Published var translatedDocument: TranslatedDocument?

    @Published var showFilePicker = false
    @Published var showSourcePicker = false
    @Published var showTargetPicker = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var exportImages: [UIImage] = []

    private let svc = TranslationService.shared
    private let proc = DocumentProcessor.shared

    func fileSelected(url: URL) {
        selectedFileURL = url
        selectedFileName = url.lastPathComponent
        translationResult = nil
        exportImages = DocumentProcessor.shared.renderPages(from: url)
    }

    func translate() async {
        isTranslating = true
        translationProgress = 0
        currentStep = .uploading
        defer { isTranslating = false }

        do {
            var text = inputText
            var pageCount = 1

            if let url = selectedFileURL, text.isEmpty {
                currentStep = .extracting
                translationProgress = 0.2
                let result = try await proc.extractText(from: url)
                text = result.text
                pageCount = result.pageCount
            }

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationError.emptyText
            }

            if autoDetect {
                currentStep = .detecting
                translationProgress = 0.3
                if let detected = svc.detectLanguage(in: text), detected.id != targetLanguage.id {
                    sourceLanguage = detected
                }
            }

            let translated = try await svc.translate(
                text: text,
                from: sourceLanguage,
                to: targetLanguage,
                detectSource: autoDetect
            ) { [weak self] step in
                Task { @MainActor [weak self] in
                    self?.currentStep = step
                    self?.translationProgress = step.progress
                }
            }

            currentStep = .complete
            translationProgress = 1.0

            var docType = DocumentType.text
            var fileSize = "—"
            if let url = selectedFileURL {
                docType = docTypeFor(url.pathExtension.lowercased())
                fileSize = proc.formattedFileSize(url: url)
            }

            let doc = TranslatedDocument(
                fileName: selectedFileName?.components(separatedBy: ".").first ?? "Document",
                originalLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                documentType: docType,
                translatedText: translated,
                originalText: text,
                pageCount: pageCount,
                fileSize: fileSize
            )
            translationResult = doc
            translatedDocument = doc
            if exportImages.isEmpty, let url = selectedFileURL {
                exportImages = proc.renderPages(from: url)
            }
            AppAnalytics.log("translation_completed", [
                "source": sourceLanguage.code,
                "target": targetLanguage.code,
                "pages": pageCount
            ])
            ReviewPromptService.shared.considerPrompt(after: "translate")

        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func docTypeFor(_ ext: String) -> DocumentType {
        switch ext {
        case "pdf":                          return .pdf
        case "docx", "doc":                  return .word
        case "xlsx", "xls", "csv":           return .excel
        case "pptx", "ppt":                  return .powerPoint
        case "jpg","jpeg","png","heic","gif","bmp","tiff","webp": return .image
        default:                             return .text
        }
    }
}
