import Foundation
import UIKit

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published var documents: [TranslatedDocument] = []

    private let metadataKey = "persistedDocumentHistory"
    private let saveHistoryKey = "saveHistory"
    private var didLoad = false

    private var pagesDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HistoryPages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        loadIfNeeded()
    }

    var isSavingEnabled: Bool {
        if UserDefaults.standard.object(forKey: saveHistoryKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: saveHistoryKey)
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let items = try? JSONDecoder().decode([TranslatedDocument].self, from: data) else {
            documents = []
            return
        }
        documents = items
        BrandingStore.seedCompletedDocumentsIfNeeded(items)
    }

    func add(
        _ document: TranslatedDocument,
        images: [UIImage] = [],
        signed: Bool = false,
        unsignedImages: [UIImage]? = nil,
        replaceSignedPages: Bool = false
    ) {
        guard isSavingEnabled else { return }
        var stored = document
        let existing = documents.first { $0.id == stored.id }
        stored.wasSigned = signed || document.wasSigned == true || (existing?.wasSigned == true && !replaceSignedPages)
        if replaceSignedPages {
            stored.wasSigned = signed || document.wasSigned == true
        }
        stored.wasConverted = document.wasConverted == true || existing?.wasConverted == true
        stored.wasEdited = document.wasEdited == true || existing?.wasEdited == true
        stored.brandingRemoved = document.brandingRemoved == true || existing?.brandingRemoved == true || BrandingStore.hasRemovedTag(for: stored.id)
        if document.requiresFaceID == true {
            stored.requiresFaceID = true
        } else if document.requiresFaceID == false {
            stored.requiresFaceID = false
        } else {
            stored.requiresFaceID = existing?.requiresFaceID
        }
        stored.confidentialFileName = document.confidentialFileName ?? existing?.confidentialFileName
        stored.unsignedPageImageFileNames = document.unsignedPageImageFileNames ?? existing?.unsignedPageImageFileNames
        if stored.wasSigned == true, !signed, !replaceSignedPages, let existingName = existing?.fileName {
            stored.fileName = existingName
        }
        if let unsignedImages, !unsignedImages.isEmpty, stored.unsignedPageImageFileNames == nil, stored.requiresFaceID != true {
            stored.unsignedPageImageFileNames = persist(unsignedImages, for: document.id, suffix: "unsigned")
        }
        var sealedThisSave = false
        if stored.requiresFaceID == true, !images.isEmpty, ConfidentialStore.canSeal(stored.id) {
            do {
                if let existing { deletePageFiles(for: existing, keepUnsigned: true) }
                let name = try ConfidentialStore.writeSealed(
                    id: stored.id,
                    images: images,
                    originalText: stored.originalText,
                    translatedText: stored.translatedText
                )
                stored.confidentialFileName = name
                stored.pageImageFileNames = nil
                stored.thumbnailData = nil
                stored.originalText = ""
                stored.translatedText = ""
                stored.pageCount = max(stored.pageCount, images.count)
                sealedThisSave = true
            } catch {
                stored.requiresFaceID = false
                stored.confidentialFileName = nil
            }
        }
        if stored.requiresFaceID != true {
            ConfidentialStore.removeProtection(id: stored.id)
            if let sealed = stored.confidentialFileName {
                try? FileManager.default.removeItem(at: ConfidentialStore.sealedDirectory().appendingPathComponent(sealed))
            }
            stored.confidentialFileName = nil
        }
        if !images.isEmpty, stored.requiresFaceID != true {
            let wouldWipeSignedPages = existing?.wasSigned == true
                && !signed
                && document.wasSigned != true
                && document.wasEdited != true
                && !replaceSignedPages
            if wouldWipeSignedPages {
                stored.pageImageFileNames = existing?.pageImageFileNames
                stored.thumbnailData = stored.thumbnailData ?? existing?.thumbnailData
            } else {
                if let old = existing { deletePageFiles(for: old, keepUnsigned: true) }
                stored.pageImageFileNames = persist(images, for: document.id)
                stored.thumbnailData = thumbnailData(from: images[0])
                stored.pageCount = max(stored.pageCount, images.count)
            }
        } else if let existing, !sealedThisSave {
            if stored.requiresFaceID == true, existing.confidentialFileName != nil {
                stored.pageImageFileNames = nil
                stored.thumbnailData = nil
                stored.originalText = ""
                stored.translatedText = ""
                stored.confidentialFileName = existing.confidentialFileName
            } else {
                if stored.requiresFaceID == true {
                    stored.requiresFaceID = false
                }
                stored.pageImageFileNames = existing.pageImageFileNames
                stored.thumbnailData = stored.thumbnailData ?? existing.thumbnailData
                stored.confidentialFileName = existing.confidentialFileName
                if stored.originalText.isEmpty { stored.originalText = existing.originalText }
                if stored.translatedText.isEmpty { stored.translatedText = existing.translatedText }
            }
        }
        documents.removeAll { $0.id == stored.id }
        documents.insert(stored, at: 0)
        if stored.wasEdited == true || stored.wasSigned == true {
            BrandingStore.recordCompletedDocument(stored.id)
        }
        if documents.count > 50 {
            let extra = documents.suffix(from: 50)
            extra.forEach { deletePageFiles(for: $0, keepUnsigned: false) }
            documents = Array(documents.prefix(50))
        }
        persistMetadata()
    }

    func images(for document: TranslatedDocument) -> [UIImage] {
        let stored = documents.first(where: { $0.id == document.id }) ?? document
        if stored.requiresFaceID == true {
            return []
        }
        return loadImages(named: stored.pageImageFileNames ?? document.pageImageFileNames)
    }

    func unlockConfidential(_ document: TranslatedDocument) async throws -> OpenedConfidentialDocument {
        let stored = documents.first(where: { $0.id == document.id }) ?? document
        guard let name = stored.confidentialFileName else {
            throw ConfidentialError.missingKey
        }
        let url = pagesDirectory.appendingPathComponent(name)
        return try await ConfidentialStore.open(id: stored.id, fileURL: url)
    }

    func unsignedImages(for document: TranslatedDocument) -> [UIImage] {
        let stored = documents.first(where: { $0.id == document.id }) ?? document
        return loadImages(named: stored.unsignedPageImageFileNames)
    }

    func delete(id: UUID) {
        if let match = documents.first(where: { $0.id == id }) {
            deletePageFiles(for: match, keepUnsigned: false)
            if let sealed = match.confidentialFileName {
                try? FileManager.default.removeItem(at: pagesDirectory.appendingPathComponent(sealed))
            }
            ConfidentialStore.removeProtection(id: id)
        }
        documents.removeAll { $0.id == id }
        persistMetadata()
    }

    func clearAll() {
        documents.forEach { deletePageFiles(for: $0, keepUnsigned: false) }
        documents.removeAll()
        persistMetadata()
    }

    private func loadImages(named names: [String]?) -> [UIImage] {
        (names ?? []).compactMap { name in
            let url = pagesDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }
    }

    private func persist(_ images: [UIImage], for id: UUID, suffix: String = "") -> [String] {
        images.enumerated().compactMap { index, image in
            let tag = suffix.isEmpty ? "\(index)" : "\(suffix)_\(index)"
            let name = "\(id.uuidString)_\(tag).jpg"
            let url = pagesDirectory.appendingPathComponent(name)
            let scaled = image.historyScaled(maxSide: 1600)
            guard let data = scaled.jpegData(compressionQuality: 0.82) else { return nil }
            try? data.write(to: url, options: .atomic)
            return name
        }
    }

    private func thumbnailData(from image: UIImage) -> Data? {
        image.historyScaled(maxSide: 240).jpegData(compressionQuality: 0.7)
    }

    private func deletePageFiles(for document: TranslatedDocument, keepUnsigned: Bool) {
        var names = document.pageImageFileNames ?? []
        if !keepUnsigned {
            names.append(contentsOf: document.unsignedPageImageFileNames ?? [])
        }
        for name in names {
            try? FileManager.default.removeItem(at: pagesDirectory.appendingPathComponent(name))
        }
    }

    private func persistMetadata() {
        if let data = try? JSONEncoder().encode(documents) {
            UserDefaults.standard.set(data, forKey: metadataKey)
        }
    }
}

private extension UIImage {
    func historyScaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
