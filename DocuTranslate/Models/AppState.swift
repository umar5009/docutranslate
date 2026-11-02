import SwiftUI
import Combine

struct DocumentPreviewRequest: Identifiable {
    let id: UUID
    let document: TranslatedDocument

    init(_ document: TranslatedDocument) {
        self.id = UUID()
        self.document = document
    }
}

class AppState: ObservableObject {
    @Published var currentTab: Tab = .home
    @Published var recentDocuments: [TranslatedDocument] = []
    @Published var showOnboarding: Bool = false
    @Published var documentToPreview: DocumentPreviewRequest?

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

    func addDocument(
        _ doc: TranslatedDocument,
        images: [UIImage] = [],
        signed: Bool = false,
        unsignedImages: [UIImage]? = nil,
        replaceSignedPages: Bool = false
    ) {
        HistoryStore.shared.add(
            doc,
            images: images,
            signed: signed,
            unsignedImages: unsignedImages,
            replaceSignedPages: replaceSignedPages
        )
    }

    func storedDocument(for document: TranslatedDocument) -> TranslatedDocument {
        HistoryStore.shared.documents.first(where: { $0.id == document.id }) ?? document
    }

    func openDocument(_ document: TranslatedDocument) {
        documentToPreview = DocumentPreviewRequest(storedDocument(for: document))
    }

    func revealSavedDocument(_ document: TranslatedDocument) {
        currentTab = .history
        // Wait for the History tab (and any export sheet) to settle so the preview
        // can present on top of the tab bar instead of being swallowed.
        Task { @MainActor in
            documentToPreview = nil
            try? await Task.sleep(nanoseconds: 350_000_000)
            openDocument(document)
        }
    }

    func exportAndReveal(
        _ document: TranslatedDocument,
        images: [UIImage],
        preferExistingImages: Bool = false
    ) async {
        var doc = document
        let alreadySigned = HistoryStore.shared.documents.first(where: { $0.id == document.id })?.wasSigned == true
        if alreadySigned { doc.wasSigned = true }
        let keepImages = preferExistingImages || doc.wasSigned == true || doc.wasEdited == true
        let pages = ExportService.shared.imagesForSigning(
            doc,
            existing: images,
            preferExisting: keepImages
        )
        addDocument(doc, images: pages, signed: alreadySigned || doc.wasSigned == true)
        revealSavedDocument(doc)
    }

    func images(for document: TranslatedDocument) -> [UIImage] {
        HistoryStore.shared.images(for: storedDocument(for: document))
    }

    func deleteDocuments(ids: [UUID]) {
        ids.forEach { HistoryStore.shared.delete(id: $0) }
    }

    func clearHistory() {
        HistoryStore.shared.clearAll()
    }
}
