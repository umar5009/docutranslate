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
    @Published var pendingSave: PendingDocumentSave?
    @Published var saveGateError: String?

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
        replaceSignedPages: Bool = false,
        confirmProtection: Bool = false,
        revealAfter: Bool = false
    ) {
        if confirmProtection {
            pendingSave = PendingDocumentSave(
                document: doc,
                images: images,
                signed: signed,
                unsignedImages: unsignedImages,
                replaceSignedPages: replaceSignedPages,
                revealAfter: revealAfter
            )
            return
        }
        commitDocument(
            doc,
            images: images,
            signed: signed,
            unsignedImages: unsignedImages,
            replaceSignedPages: replaceSignedPages
        )
    }

    func finishPendingSave(_ choice: SaveProtectionChoice) async {
        guard var pending = pendingSave else { return }
        switch choice {
        case .cancel:
            pendingSave = nil
        case .standard:
            pending.document.requiresFaceID = false
            ConfidentialStore.removeProtection(id: pending.document.id)
            pendingSave = nil
            commitDocument(
                pending.document,
                images: pending.images,
                signed: pending.signed,
                unsignedImages: pending.unsignedImages,
                replaceSignedPages: pending.replaceSignedPages
            )
            if pending.revealAfter { revealSavedDocument(pending.document) }
        case .faceID:
            do {
                try await ConfidentialStore.authorizeAndArm(id: pending.document.id)
                pending.document.requiresFaceID = true
                pendingSave = nil
                commitDocument(
                    pending.document,
                    images: pending.images,
                    signed: pending.signed,
                    unsignedImages: pending.unsignedImages,
                    replaceSignedPages: pending.replaceSignedPages
                )
                if pending.revealAfter { revealSavedDocument(pending.document) }
            } catch {
                saveGateError = error.localizedDescription
            }
        }
    }

    private func commitDocument(
        _ doc: TranslatedDocument,
        images: [UIImage],
        signed: Bool,
        unsignedImages: [UIImage]?,
        replaceSignedPages: Bool
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
        addDocument(
            doc,
            images: pages,
            signed: alreadySigned || doc.wasSigned == true,
            confirmProtection: true,
            revealAfter: true
        )
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
