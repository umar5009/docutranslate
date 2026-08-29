import SwiftUI

struct TranslatedDocumentPreview: View {
    let document: TranslatedDocument
    var scannedImages: [UIImage] = []
    var onSignStamp: (() -> Void)?

    @State private var selectedTab: PreviewTab = .translated
    @State private var previewPage = 0

    enum PreviewTab: String, CaseIterable {
        case original = "Original"
        case translated = "Translated"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBar
            languageRoute
            tabPicker
            documentPage
            if pageCount > 1 {
                pageNavigator
            }
            if let onSignStamp {
                Button(action: onSignStamp) {
                    Label("Sign / Stamp", systemImage: "signature")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(14)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .onChange(of: document.id) { _, _ in
            previewPage = 0
        }
    }

    private var headerBar: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Translation Complete")
                .font(.headline)
            Spacer()
            Text(document.formattedDate)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var languageRoute: some View {
        HStack(spacing: 8) {
            languageBadge(
                flag: document.originalLanguage.flag,
                name: document.originalLanguage.name,
                color: .blue
            )
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundColor(.secondary)
            languageBadge(
                flag: document.targetLanguage.flag,
                name: document.targetLanguage.name,
                color: .green
            )
            Spacer()
            Text("\(wordCount) words")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func languageBadge(flag: String, name: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(flag)
            Text(name)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.1))
        .foregroundColor(color)
        .cornerRadius(20)
    }

    private var tabPicker: some View {
        Picker("Preview", selection: $selectedTab) {
            ForEach(PreviewTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    private var documentPage: some View {
        VStack(spacing: 0) {
            // Document header strip
            HStack {
                Image(systemName: document.documentType.icon)
                    .foregroundColor(Color(hex: document.documentType.color))
                Text(document.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(previewPage + 1)/\(pageCount) pg")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(hex: "#1a56d6").opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if selectedTab == .translated, let pageImage = currentPreviewImage {
                        Image(uiImage: pageImage)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color(.systemGray4), lineWidth: 1)
                            )
                    }

                    formattedText(currentText)
                }
                .padding(20)
            }
            .frame(maxHeight: 420)
            .background(Color(.systemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.systemGray4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }

    private var pageCount: Int {
        max(
            document.pageCount,
            document.translatedPageTexts.count,
            document.originalPageTexts.count,
            scannedImages.count,
            1
        )
    }

    private var currentPreviewImage: UIImage? {
        guard previewPage < scannedImages.count else { return scannedImages.first }
        return scannedImages[previewPage]
    }

    private var currentText: String {
        let pages = selectedTab == .translated ? document.translatedPageTexts : document.originalPageTexts
        if previewPage < pages.count {
            return DocumentPageBreak.displayText(pages[previewPage])
        }
        return DocumentPageBreak.displayText(selectedTab == .translated ? document.translatedText : document.originalText)
    }

    private var pageNavigator: some View {
        HStack(spacing: 16) {
            Button {
                previewPage = max(previewPage - 1, 0)
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title3)
            }
            .disabled(previewPage <= 0)

            Text("Page \(previewPage + 1) of \(pageCount)")
                .font(.subheadline.weight(.semibold))

            Button {
                previewPage = min(previewPage + 1, pageCount - 1)
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title3)
            }
            .disabled(previewPage >= pageCount - 1)
        }
        .foregroundColor(.blue)
        .frame(maxWidth: .infinity)
    }

    private var wordCount: Int {
        DocumentPageBreak.displayText(document.translatedText).split(whereSeparator: \.isWhitespace).count
    }

    @ViewBuilder
    private func formattedText(_ text: String) -> some View {
        let paragraphs = text.components(separatedBy: "\n\n")
        if paragraphs.count > 1 {
            ForEach(paragraphs.indices, id: \.self) { i in
                let para = paragraphs[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !para.isEmpty {
                    Text(para)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        } else {
            let lines = text.components(separatedBy: "\n")
            ForEach(lines.indices, id: \.self) { i in
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer().frame(height: 8)
                } else if line.hasPrefix("Điều") || line.hasPrefix("Article") || line.hasPrefix("CHƯƠNG") || line.hasPrefix("Chapter") {
                    Text(line)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                } else if line.range(of: "^\\d+\\.", options: .regularExpression) != nil {
                    Text(line)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                } else {
                    Text(line)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
