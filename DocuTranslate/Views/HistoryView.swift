import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedFilter: HistoryFilter = .all
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var isPreparingShare = false
    @State private var shareError: String?
    @State private var pendingShare: PendingProtectedShare?

    enum HistoryFilter: String, CaseIterable {
        case all = "All"
        case pdf = "PDF"
        case word = "Word"
        case scanned = "Scanned"
        case signed = "Signed"
        case favorites = "Favorites"
    }

    private var filteredDocuments: [TranslatedDocument] {
        var docs = appState.recentDocuments

        switch selectedFilter {
        case .pdf:       docs = docs.filter { $0.documentType == .pdf }
        case .word:      docs = docs.filter { $0.documentType == .word }
        case .scanned:   docs = docs.filter { $0.documentType == .scanned }
        case .signed:    docs = docs.filter { $0.wasSigned == true }
        case .favorites: docs = docs.filter { $0.isFavorite }
        case .all:       break
        }

        if !searchText.isEmpty {
            docs = docs.filter {
                $0.fileName.localizedCaseInsensitiveContains(searchText) ||
                $0.targetLanguage.name.localizedCaseInsensitiveContains(searchText) ||
                $0.originalLanguage.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        return docs
    }

    private var groupedDocuments: [HistoryDayGroup] {
        HistoryDayGroup.groups(from: filteredDocuments)
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.recentDocuments.isEmpty {
                    emptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !appState.recentDocuments.isEmpty {
                        Button("Clear All", action: AppAnalytics.action("history_clear_all") {
                            appState.clearHistory()
                        })
                        .foregroundColor(.red)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search documents...")
            .sheet(isPresented: $showShareSheet) {
                ActivityShareSheet(items: shareItems)
            }
            .sheet(item: $pendingShare) { share in
                ShareKeyCodeSheet(code: share.code, fileName: share.document.fileName) {
                    Task { await finishProtectedShare(share) }
                }
            }
            .overlay {
                if isPreparingShare {
                    ExportingOverlay(message: "Preparing…")
                }
            }
            .alert("Couldn’t Share", isPresented: .init(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            )) {
                Button("OK", role: .cancel, action: AppAnalytics.action("history_share_error_ok") { shareError = nil })
            } message: {
                Text(shareError ?? "")
            }
        }
    }

    private func shareDocument(_ document: TranslatedDocument) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            var images = appState.images(for: document)
            if document.requiresFaceID == true, images.isEmpty {
                images = try await HistoryStore.shared.unlockConfidential(document).pages
            }
            pendingShare = PendingProtectedShare(
                document: document,
                images: images,
                code: ShareKeyCode.make()
            )
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func finishProtectedShare(_ share: PendingProtectedShare) async {
        pendingShare = nil
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await ExportService.shared.makeShareFile(
                document: share.document,
                images: share.images,
                password: share.code
            )
            shareItems = [url]
            showShareSheet = true
        } catch {
            shareError = error.localizedDescription
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.secondary)
            Text("No History Yet")
                .font(.title3.bold())
            Text("Generated, translated, and signed documents will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var documentList: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HistoryFilter.allCases, id: \.self) { filter in
                        FilterButton(
                            title: filter.rawValue,
                            isSelected: selectedFilter == filter
                        ) {
                            AppAnalytics.tap("history_filter", ["filter": filter.rawValue])
                            selectedFilter = filter
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            Divider()

            if filteredDocuments.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No results")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(groupedDocuments) { group in
                        Section {
                            ForEach(group.documents) { doc in
                                HistoryRow(
                                    document: doc,
                                    onView: {
                                        AppAnalytics.tap("history_open", ["file": doc.fileName])
                                        appState.openDocument(doc)
                                    },
                                    onShare: {
                                        AppAnalytics.tap("history_share", ["file": doc.fileName])
                                        Task { await shareDocument(doc) }
                                    }
                                )
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                            }
                            .onDelete { indexSet in
                                AppAnalytics.tap("history_delete")
                                let ids = indexSet.map { group.documents[$0].id }
                                appState.deleteDocuments(ids: ids)
                            }
                        } header: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(group.title)
                                    .font(.title3.weight(.bold))
                                    .foregroundColor(.primary)
                                    .textCase(nil)
                                Spacer()
                                Text(group.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textCase(nil)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Date Groups

struct HistoryDayGroup: Identifiable {
    let id: Date
    let title: String
    let documents: [TranslatedDocument]

    var subtitle: String {
        let count = documents.count
        return count == 1 ? "1 document" : "\(count) documents"
    }

    static func groups(from documents: [TranslatedDocument]) -> [HistoryDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: documents) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            HistoryDayGroup(
                id: day,
                title: title(for: day, calendar: calendar),
                documents: (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            )
        }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("EEEE, MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEEE, MMM d, yyyy")
        }
        return formatter.string(from: day)
    }
}

// MARK: - History Row

struct HistoryRow: View {
    let document: TranslatedDocument
    let onView: () -> Void
    let onShare: () -> Void

    var body: some View {
        Button(action: onView) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: document.documentType.color).opacity(0.12))
                        .frame(width: 52, height: 64)
                    if document.requiresFaceID == true {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Color(hex: document.documentType.color))
                    } else if let thumb = document.thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: document.documentType.icon)
                            .font(.system(size: 22))
                            .foregroundColor(Color(hex: document.documentType.color))
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(document.fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(document.originalLanguage.flag)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text(document.targetLanguage.flag)
                        Text(document.targetLanguage.name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(document.documentType.rawValue)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(Color(hex: document.documentType.color))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(hex: document.documentType.color).opacity(0.1))
                            .cornerRadius(6)
                        if document.wasSigned == true {
                            Text("Signed")
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.blue)
                                .cornerRadius(6)
                        }
                        if document.wasEdited == true {
                            Text("Edited")
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(hex: "#FF375F"))
                                .cornerRadius(6)
                        }
                    }

                    Text(document.formattedDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.borderless)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(.systemBackground))
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Document Viewer

struct HistoryDocumentViewer: View {
    let document: TranslatedDocument
    let images: [UIImage]
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var liveDocument: TranslatedDocument
    @State private var liveImages: [UIImage]
    @State private var pageIndex = 0
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isPreparingShare = false
    @State private var shareError: String?
    @State private var showText = false
    @State private var showDocumentEditor = false
    @State private var editorMode: DocumentEditorMode = .edit
    @State private var showSignStampEditor = false
    @State private var unsignedSnapshot: [UIImage] = []
    @State private var showRemoveStampConfirm = false
    @State private var showPaywall = false
    @State private var pendingShare: PendingProtectedShare?
    @State private var unlocking = false
    @State private var didRequestUnlock = false

    init(document: TranslatedDocument, images: [UIImage]) {
        self.document = document
        self.images = images
        _liveDocument = State(initialValue: document)
        _liveImages = State(initialValue: images)
    }

    private var isFaceIDLocked: Bool {
        liveDocument.requiresFaceID == true && liveImages.isEmpty
    }

    private var pages: [UIImage] {
        if isFaceIDLocked { return [] }
        return liveImages.isEmpty
            ? ExportService.shared.imagesForSigning(liveDocument, existing: [])
            : liveImages
    }

    private var hasText: Bool {
        !document.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !document.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if liveDocument.showsBrandingTag {
                    RemoveBrandingBanner(document: $liveDocument, compact: true) { updated in
                        appState.addDocument(updated, images: liveImages, signed: updated.wasSigned == true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                if isFaceIDLocked {
                    faceIDLock
                } else if showText, hasText {
                    textPreview
                } else if pages.isEmpty {
                    emptyPreview
                } else {
                    pagePreview
                }
                if !pages.isEmpty {
                    documentActions
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(liveDocument.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done", action: AppAnalytics.action("history_viewer_done") {
                        appState.documentToPreview = nil
                        dismiss()
                    })
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if hasText, !pages.isEmpty {
                            Button {
                                AppAnalytics.tap(showText ? "history_show_pages" : "history_show_text")
                                showText.toggle()
                            } label: {
                                Image(systemName: showText ? "photo" : "text.alignleft")
                            }
                        }
                        Button {
                            AppAnalytics.tap("history_viewer_share")
                            Task { await shareCurrentDocument() }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(isPreparingShare)
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ActivityShareSheet(items: shareItems)
            }
            .sheet(item: $pendingShare) { share in
                ShareKeyCodeSheet(code: share.code, fileName: share.document.fileName) {
                    Task { await finishProtectedShare(share) }
                }
            }
            .sheet(isPresented: $showPaywall) {
                RemoveTagPaymentSheet(documentID: liveDocument.id) {
                    liveDocument.brandingRemoved = true
                    appState.addDocument(liveDocument, images: liveImages, signed: liveDocument.wasSigned == true)
                }
            }
            .fullScreenCover(isPresented: $showDocumentEditor) {
                DocumentEditorView(
                    pages: liveImages.isEmpty
                        ? ExportService.shared.imagesForSigning(liveDocument, existing: [])
                        : liveImages,
                    pageIndex: pageIndex,
                    fileName: liveDocument.fileName,
                    initialMode: editorMode
                ) { edited in
                    applyEditedPages(edited)
                }
            }
            .sheet(isPresented: $showSignStampEditor) {
                SignStampEditorView(
                    pages: liveImages.isEmpty
                        ? ExportService.shared.imagesForSigning(liveDocument, existing: [])
                        : liveImages,
                    pageIndex: pageIndex
                ) { signed in
                    applySignedPages(signed)
                }
            }
            .confirmationDialog(
                "Remove signature and stamp?",
                isPresented: $showRemoveStampConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove Sign / Stamp", role: .destructive) {
                    AppAnalytics.tap("history_remove_sign_stamp")
                    removeSignStamp()
                }
                Button("Cancel", role: .cancel, action: AppAnalytics.action("history_remove_cancel") {})
            } message: {
                Text("This restores the document to how it looked before the last signature or stamp.")
            }
            .overlay {
                if isPreparingShare {
                    ExportingOverlay(message: "Preparing…")
                }
            }
            .alert("Couldn’t Share", isPresented: .init(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            )) {
                Button("OK", role: .cancel, action: AppAnalytics.action("history_share_error_ok") { shareError = nil })
            } message: {
                Text(shareError ?? "")
            }
            .onAppear {
                let stored = appState.storedDocument(for: liveDocument)
                liveDocument = stored
                if stored.requiresFaceID == true {
                    if liveImages.isEmpty, !didRequestUnlock {
                        didRequestUnlock = true
                        Task { await unlockFaceID() }
                    }
                } else {
                    let storedImages = appState.images(for: stored)
                    if !storedImages.isEmpty {
                        liveImages = storedImages
                    }
                }
                if unsignedSnapshot.isEmpty {
                    unsignedSnapshot = HistoryStore.shared.unsignedImages(for: stored)
                }
            }
        }
    }

    private func applyEditedPages(_ edited: [UIImage]) {
        liveImages = edited
        liveDocument.wasEdited = true
        liveDocument.pageCount = max(liveDocument.pageCount, edited.count)
        if let thumb = edited.first {
            liveDocument.thumbnailData = thumb.jpegData(compressionQuality: 0.7)
        }
        if liveDocument.wasSigned != true {
            unsignedSnapshot = edited
        }
        appState.addDocument(
            liveDocument,
            images: edited,
            signed: liveDocument.wasSigned == true,
            unsignedImages: liveDocument.wasSigned == true ? nil : edited,
            confirmProtection: true
        )
    }

    private func applySignedPages(_ signed: [UIImage]) {
        let unsigned = unsignedSnapshot.isEmpty ? liveImages : unsignedSnapshot
        if unsignedSnapshot.isEmpty {
            unsignedSnapshot = liveImages
        }
        liveImages = signed
        liveDocument.wasSigned = true
        liveDocument.pageCount = max(liveDocument.pageCount, signed.count)
        appState.addDocument(
            liveDocument,
            images: signed,
            signed: true,
            unsignedImages: unsigned,
            confirmProtection: true
        )
    }

    private var canRemoveSignStamp: Bool {
        liveDocument.wasSigned == true
            && (!unsignedSnapshot.isEmpty || !HistoryStore.shared.unsignedImages(for: liveDocument).isEmpty)
    }

    private func removeSignStamp() {
        var restored = unsignedSnapshot
        if restored.isEmpty {
            restored = HistoryStore.shared.unsignedImages(for: liveDocument)
        }
        guard !restored.isEmpty else { return }
        liveImages = restored
        liveDocument.wasSigned = false
        appState.addDocument(
            liveDocument,
            images: restored,
            signed: false,
            replaceSignedPages: true
        )
    }

    private var documentActions: some View {
        VStack(spacing: 8) {
            DocumentEditorLaunchRow(
                onEdit: {
                    AppAnalytics.tap("history_edit_document")
                    editorMode = .edit
                    showDocumentEditor = true
                },
                onHighlight: {
                    AppAnalytics.tap("history_highlight_document")
                    editorMode = .markup
                    showDocumentEditor = true
                }
            )
            HStack(spacing: 12) {
                Button {
                    AppAnalytics.tap("history_sign_stamp")
                    if unsignedSnapshot.isEmpty {
                        let storedUnsigned = HistoryStore.shared.unsignedImages(for: liveDocument)
                        unsignedSnapshot = storedUnsigned.isEmpty ? liveImages : storedUnsigned
                    }
                    showSignStampEditor = true
                } label: {
                    Label("Sign / Stamp", systemImage: "signature")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(12)
                }
                if canRemoveSignStamp {
                    Button {
                        AppAnalytics.tap("history_remove_open")
                        showRemoveStampConfirm = true
                    } label: {
                        Label("Remove Stamp", systemImage: "xmark.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(12)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var faceIDLock: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "faceid")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.blue)
            Text("This document is locked")
                .font(.headline)
            Text("Face ID is required to open it.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button {
                Task { await unlockFaceID() }
            } label: {
                Label(unlocking ? "Waiting for Face ID…" : "Unlock with Face ID", systemImage: "lock.open")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .disabled(unlocking)
            Spacer()
        }
    }

    private func unlockFaceID() async {
        unlocking = true
        defer { unlocking = false }
        do {
            let opened = try await HistoryStore.shared.unlockConfidential(liveDocument)
            liveImages = opened.pages
            liveDocument.originalText = opened.originalText
            liveDocument.translatedText = opened.translatedText
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func shareCurrentDocument() async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            var images = liveImages
            if liveDocument.requiresFaceID == true, images.isEmpty {
                let opened = try await HistoryStore.shared.unlockConfidential(liveDocument)
                images = opened.pages
                liveImages = opened.pages
                liveDocument.originalText = opened.originalText
                liveDocument.translatedText = opened.translatedText
            }
            pendingShare = PendingProtectedShare(
                document: liveDocument,
                images: images,
                code: ShareKeyCode.make()
            )
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func finishProtectedShare(_ share: PendingProtectedShare) async {
        pendingShare = nil
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await ExportService.shared.makeShareFile(
                document: share.document,
                images: share.images,
                password: share.code
            )
            shareItems = [url]
            showShareSheet = true
        } catch {
            shareError = error.localizedDescription
        }
    }

    private var pagePreview: some View {
        VStack(spacing: 0) {
            TabView(selection: $pageIndex) {
                ForEach(pages.indices, id: \.self) { index in
                    ZoomablePageImage(
                        image: pages[index],
                        showsPaywallWatermark: liveDocument.showsBrandingTag,
                        onPaywall: {
                            AppAnalytics.tap("watermark_paywall", ["source": "history"])
                            showPaywall = true
                        }
                    )
                        .tag(index)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .automatic : .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text(liveDocument.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(pages.count > 1 ? "Page \(pageIndex + 1) of \(pages.count)" : "Hold to magnify · Pinch to zoom")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var textPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !document.translatedText.isEmpty {
                    Text("Translated")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(DocumentPageBreak.displayText(document.translatedText))
                        .font(.body)
                        .textSelection(.enabled)
                }
                if !document.originalText.isEmpty {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(DocumentPageBreak.displayText(document.originalText))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
            Text("No preview available")
                .font(.headline)
            Text("Export this document to save a file.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ZoomablePageImage: View {
    let image: UIImage
    var showsPaywallWatermark = false
    var onPaywall: (() -> Void)? = nil
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let fit = fittedSize(image.size, in: geo.size)
            ScrollView([.horizontal, .vertical], showsIndicators: scale > 1) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: fit.width * scale, height: fit.height * scale)
                    .documentMagnifier(image: image)
                    .overlay {
                        if showsPaywallWatermark {
                            PaywallWatermarkBadge(
                                canvasSize: CGSize(width: fit.width * scale, height: fit.height * scale),
                                onClose: { onPaywall?() }
                            )
                        }
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1), 6)
                            }
                            .onEnded { _ in
                                lastScale = scale
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if scale > 1 {
                                scale = 1
                                lastScale = 1
                            } else {
                                scale = 2.2
                                lastScale = 2.2
                            }
                        }
                    }
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .onAppear {
            scale = 1
            lastScale = 1
        }
    }

    private func fittedSize(_ imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let ratio = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }
}

// MARK: - Filter Button

struct FilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}
