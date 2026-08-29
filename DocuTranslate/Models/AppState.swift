import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var currentTab: Tab = .home
    @Published var recentDocuments: [TranslatedDocument] = []
    @Published var showOnboarding: Bool = false
    @Published var documentToPreview: TranslatedDocument?
    @Published var lastSavedExport: ExportService.SavedExport?

    private var historyCancellable: AnyCancellable?

    enum Tab: String, CaseIterable {
        case home = "Home"
        case scan = "Scan"
        case convert = "Convert"
        case translate = "Translate"
        case history = "History"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .scan: return "camera.viewfinder"
            case .convert: return "arrow.triangle.2.circlepath"
            case .translate: return "globe"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape.fill"
            }
        }
    }

    init() {
        HistoryStore.shared.loadIfNeeded()
        recentDocuments = HistoryStore.shared.documents
        historyCancellable = HistoryStore.shared.$documents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.recentDocuments = items
            }
    }

    func addDocument(_ doc: TranslatedDocument, images: [UIImage] = [], signed: Bool = false) {
        HistoryStore.shared.add(doc, images: images, signed: signed)
    }

    func revealSavedDocument(_ document: TranslatedDocument, export: ExportService.SavedExport) {
        lastSavedExport = export
        documentToPreview = document
        currentTab = .history
    }

    func exportAndReveal(
        _ document: TranslatedDocument,
        format: ExportFormat,
        images: [UIImage],
        preferExistingImages: Bool = false
    ) async throws {
        let pages = ExportService.shared.imagesForSigning(
            document,
            existing: images,
            preferExisting: preferExistingImages
        )
        let result = try await ExportService.shared.exportAndSave(
            document: document,
            as: format,
            scannedImages: pages
        )
        addDocument(document, images: pages, signed: document.wasSigned == true)
        revealSavedDocument(document, export: result)
    }

    func images(for document: TranslatedDocument) -> [UIImage] {
        HistoryStore.shared.images(for: document)
    }

    func deleteDocuments(ids: [UUID]) {
        ids.forEach { HistoryStore.shared.delete(id: $0) }
    }

    func clearHistory() {
        HistoryStore.shared.clearAll()
    }
}
