import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedFilter: HistoryFilter = .all
    @State private var viewingDocument: TranslatedDocument?
    @State private var exportingDocument: TranslatedDocument?

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
        NavigationView {
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
            .sheet(item: $viewingDocument) { doc in
                HistoryDocumentViewer(
                    document: doc,
                    images: appState.images(for: doc)
                )
            }
            .sheet(item: $exportingDocument) { doc in
                ExportView(document: doc, images: appState.images(for: doc))
            }
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
                                        viewingDocument = doc
                                    },
                                    onExport: {
                                        AppAnalytics.tap("history_export", ["file": doc.fileName])
                                        exportingDocument = doc
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
    let onExport: () -> Void

    var body: some View {
        Button(action: onView) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: document.documentType.color).opacity(0.12))
                        .frame(width: 52, height: 64)
                    if let thumb = document.thumbnail {
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
                    }

                    Text(document.formattedDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Button(action: onExport) {
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
    @State private var pageIndex = 0
    @State private var showExport = false
    @State private var showText = false

    init(document: TranslatedDocument, images: [UIImage]) {
        self.document = document
        self.images = images
        _liveDocument = State(initialValue: document)
    }

    private var pages: [UIImage] {
        let raw = images.isEmpty
            ? ExportService.shared.imagesForSigning(liveDocument, existing: [])
            : images
        return DocumentBranding.apply(raw, to: liveDocument)
    }

    private var hasText: Bool {
        !document.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !document.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if liveDocument.showsBrandingTag {
                    RemoveBrandingBanner(document: $liveDocument) { updated in
                        appState.addDocument(updated, images: images, signed: updated.wasSigned == true)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                if showText, hasText {
                    textPreview
                } else if pages.isEmpty {
                    emptyPreview
                } else {
                    pagePreview
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(document.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done", action: AppAnalytics.action("history_viewer_done") { dismiss() })
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
                            AppAnalytics.tap("history_viewer_export")
                            showExport = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showExport) {
                ExportView(document: liveDocument, images: images)
            }
        }
    }

    private var pagePreview: some View {
        VStack(spacing: 0) {
            TabView(selection: $pageIndex) {
                ForEach(pages.indices, id: \.self) { index in
                    ZoomablePageImage(image: pages[index])
                        .tag(index)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .automatic : .never))

            HStack {
                Text(document.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if pages.count > 1 {
                    Text("Page \(pageIndex + 1) of \(pages.count)")
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var textPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !document.translatedText.isEmpty {
                    Text("Translated")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(document.translatedText)
                        .font(.body)
                        .textSelection(.enabled)
                }
                if !document.originalText.isEmpty {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(document.originalText)
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
    @State private var scale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width)
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(value, 1), 5)
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1 ? 1 : 2.2
                        }
                    }
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
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
