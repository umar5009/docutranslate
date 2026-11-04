import CryptoKit
import LocalAuthentication
import Security
import SwiftUI
import UIKit

struct OpenedConfidentialDocument {
    var pages: [UIImage]
    var originalText: String
    var translatedText: String
}

enum SaveProtectionChoice {
    case faceID
    case standard
    case cancel
}

struct PendingDocumentSave: Identifiable {
    let id = UUID()
    var document: TranslatedDocument
    var images: [UIImage]
    var signed: Bool
    var unsignedImages: [UIImage]?
    var replaceSignedPages: Bool
    var revealAfter: Bool
}

enum ShareKeyCode {
    static func make() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let chars = (0..<8).map { _ in alphabet.randomElement()! }
        return "\(String(chars.prefix(4)))-\(String(chars.suffix(4)))"
    }
}

struct PendingProtectedShare: Identifiable {
    let id = UUID()
    var document: TranslatedDocument
    var images: [UIImage]
    var code: String
}

enum ConfidentialStore {
    private static let service = "com.docutranslate.confidential"
    private static var armedKeys: [UUID: SymmetricKey] = [:]

    private struct Blob: Codable {
        var originalText: String
        var translatedText: String
        var pages: [Data]
    }

    static func canSeal(_ id: UUID) -> Bool {
        armedKeys[id] != nil
    }

    static func authorizeAndArm(id: UUID) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw ConfidentialError.unavailable(error?.localizedDescription ?? "Face ID is not available on this device.")
        }
        let confirmed = try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Lock this document with Face ID"
        )
        guard confirmed else { throw ConfidentialError.unavailable("Face ID was not confirmed.") }
        let key = SymmetricKey(size: .bits256)
        try store(key: key, id: id, context: context)
        armedKeys[id] = key
    }

    static func writeSealed(
        id: UUID,
        images: [UIImage],
        originalText: String,
        translatedText: String
    ) throws -> String {
        guard let key = armedKeys[id] else { throw ConfidentialError.missingKey }
        let pages = images.compactMap { image -> Data? in
            scaled(image, maxSide: 1600).jpegData(compressionQuality: 0.82)
        }
        let blob = Blob(originalText: originalText, translatedText: translatedText, pages: pages)
        let encoded = try JSONEncoder().encode(blob)
        let sealed = try AES.GCM.seal(encoded, using: key)
        guard let combined = sealed.combined else { throw ConfidentialError.missingKey }
        let name = "\(id.uuidString).sealed"
        let url = sealedDirectory().appendingPathComponent(name)
        try combined.write(to: url, options: .completeFileProtection)
        return name
    }

    static func open(id: UUID, fileURL: URL) async throws -> OpenedConfidentialDocument {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        let confirmed = try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock this document with Face ID"
        )
        guard confirmed else { throw ConfidentialError.unavailable("Face ID was not confirmed.") }
        let key = try loadKey(id: id, context: context)
        let combined = try Data(contentsOf: fileURL)
        let box = try AES.GCM.SealedBox(combined: combined)
        let clear = try AES.GCM.open(box, using: key)
        let blob = try JSONDecoder().decode(Blob.self, from: clear)
        let pages = blob.pages.compactMap { UIImage(data: $0) }
        armedKeys[id] = key
        return OpenedConfidentialDocument(
            pages: pages,
            originalText: blob.originalText,
            translatedText: blob.translatedText
        )
    }

    static func removeProtection(id: UUID) {
        armedKeys[id] = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func sealedDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HistoryPages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func store(key: SymmetricKey, id: UUID, context: LAContext) throws {
        let data = key.withUnsafeBytes { Data($0) }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            throw ConfidentialError.unavailable("This device cannot store a Face ID key.")
        }
        removeProtection(id: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ConfidentialError.unavailable("Face ID could not lock this document (\(status)).")
        }
    }

    private static func loadKey(id: UUID, context: LAContext) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw ConfidentialError.unavailable("Face ID could not unlock this document.")
        }
        return SymmetricKey(data: data)
    }
}

private func scaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > maxSide, longest > 0 else { return image }
    let scale = maxSide / longest
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: newSize))
    }
}

enum ConfidentialError: LocalizedError {
    case unavailable(String)
    case missingKey

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .missingKey: return "This document could not be locked."
        }
    }
}

struct ConfidentialSaveSheet: View {
    let fileName: String
    var onChoice: (SaveProtectionChoice) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "faceid")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.blue)
                Text("Save this document with Face ID?")
                    .font(.title3.weight(.semibold))
                Text("\(fileName) stays in the app. Face ID is required to open it again. You can also save it without a lock.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button {
                    onChoice(.faceID)
                } label: {
                    Label("Save with Face ID", systemImage: "lock.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .cornerRadius(14)
                }
                Button {
                    onChoice(.standard)
                } label: {
                    Text("Save without Face ID")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.systemGray6))
                        .cornerRadius(14)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Confidential")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onChoice(.cancel) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ShareKeyCodeSheet: View {
    let code: String
    let fileName: String
    var onShare: () -> Void
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Give this key code to the recipient. They need it to open the file. It is not included in the share.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
                Text(fileName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy key code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.systemGray6))
                        .cornerRadius(14)
                }
                Button(action: onShare) {
                    Label("Share locked file", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .cornerRadius(14)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Share key code")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
