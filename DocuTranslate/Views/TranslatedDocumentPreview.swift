import SwiftUI

struct TranslatedDocumentPreview: View {
    let document: TranslatedDocument
    var scannedImages: [UIImage] = []
    var onSignStamp: (() -> Void)?
    var onEditDocument: (() -> Void)?
    var onHighlight: (() -> Void)?

    @State private var selectedTab: PreviewTab = .translated
    @State private var previewPage = 0
    @State private var showPaywall = false
    @State private var showDocumentViewer = false
    @State private var renderedPages: [UIImage] = []
    @ObservedObject private var brandingStore = BrandingStore.shared

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
            if onEditDocument != nil || onHighlight != nil {
                DocumentEditorLaunchRow(onEdit: onEditDocument, onHighlight: onHighlight)
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
        .onAppear(perform: loadRenderedPagesIfNeeded)
        .onChange(of: document.id) { _, _ in
            previewPage = 0
            loadRenderedPagesIfNeeded()
        }
        .sheet(isPresented: $showPaywall) {
            RemoveTagPaymentSheet(documentID: document.id) { }
        }
        .fullScreenCover(isPresented: $showDocumentViewer) {
            HistoryDocumentViewer(document: document, images: previewPages)
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
        .onChange(of: selectedTab) { _, tab in
            AppAnalytics.tap("preview_tab", ["tab": tab.rawValue])
        }
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

            if selectedTab == .translated, let pageImage = currentPreviewImage {
                Image(uiImage: pageImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .aspectRatio(pageImage.size, contentMode: .fit)
                    .background(Color.white)
                    .documentMagnifier(image: pageImage)
                    .overlay {
                        GeometryReader { geo in
                            if showsPaywallWatermark {
                                PaywallWatermarkBadge(canvasSize: geo.size) {
                                    AppAnalytics.tap("watermark_paywall", ["source": "preview"])
                                    showPaywall = true
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(.systemGray4), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            Text("Hold your finger on a line to read it in the lens.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            Button {
                AppAnalytics.tap("preview_view_document")
                showDocumentViewer = true
            } label: {
                Label("View document", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                formattedText(currentText)
                    .padding(20)
            }
            .frame(maxHeight: 220)
            .background(Color(.systemBackground))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.systemGray4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }

    private var showsPaywallWatermark: Bool {
        _ = brandingStore.watermarkRevision
        return document.showsBrandingTag
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

    private var previewPages: [UIImage] {
        if !scannedImages.isEmpty { return scannedImages }
        return renderedPages
    }

    private var currentPreviewImage: UIImage? {
        guard !previewPages.isEmpty else { return nil }
        if previewPage < previewPages.count { return previewPages[previewPage] }
        return previewPages.first
    }

    private func loadRenderedPagesIfNeeded() {
        guard scannedImages.isEmpty else { return }
        let doc = document
        renderedPages = ExportService.shared.renderTextPages(doc)
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
                AppAnalytics.tap("preview_prev_page")
                previewPage = max(previewPage - 1, 0)
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title3)
            }
            .disabled(previewPage <= 0)

            Text("Page \(previewPage + 1) of \(pageCount)")
                .font(.subheadline.weight(.semibold))

            Button {
                AppAnalytics.tap("preview_next_page")
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
