import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var showDocumentPicker = false
    @State private var selectedDocument: TranslatedDocument?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // Hero banner
                    heroBanner

                    VStack(spacing: 24) {
                        // Quick actions
                        quickActions

                        // Supported formats
                        supportedFormats

                        // Recent documents
                        if !appState.recentDocuments.isEmpty {
                            recentDocuments
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("DocuTranslate")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        AppAnalytics.tap("home_settings")
                        appState.currentTab = .settings
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .sheet(item: $selectedDocument) { doc in
                HistoryDocumentViewer(
                    document: doc,
                    images: appState.images(for: doc)
                )
            }
        }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#1a56d6"), Color(hex: "#0f3a9e")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundColor(.white.opacity(0.9))

                Text("Translate Any Document")
                    .font(.title2.bold())
                    .foregroundColor(.white)

                Text("60+ languages • Scan, sign, stamp & export")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.75))

                Button {
                    AppAnalytics.tap("home_start_translate")
                    appState.currentTab = .translate
                } label: {
                    Label("Start Translating", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .foregroundColor(Color(hex: "#1a56d6"))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.white)
                        .cornerRadius(25)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 36)
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Quick Actions")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                QuickActionCard(
                    icon: "doc.badge.plus",
                    title: "Upload Document",
                    subtitle: "PDF, Word, Excel, PPT...",
                    color: Color(hex: "#1a56d6")
                ) {
                    AppAnalytics.tap("home_upload_document")
                    appState.currentTab = .translate
                }

                QuickActionCard(
                    icon: "camera.viewfinder",
                    title: "Scan Document",
                    subtitle: "Camera + auto-crop",
                    color: Color(hex: "#8B5CF6")
                ) {
                    AppAnalytics.tap("home_scan_document")
                    appState.currentTab = .scan
                }

                QuickActionCard(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Convert File",
                    subtitle: "PDF, Word, Excel, images",
                    color: Color(hex: "#0EA5E9")
                ) {
                    AppAnalytics.tap("home_convert_file")
                    appState.currentTab = .convert
                }

                QuickActionCard(
                    icon: "signature",
                    title: "Sign & Stamp",
                    subtitle: "Sign and seal documents",
                    color: Color(hex: "#DC2626")
                ) {
                    AppAnalytics.tap("home_sign_stamp")
                    appState.currentTab = .scan
                }

                QuickActionCard(
                    icon: "clock.arrow.circlepath",
                    title: "View History",
                    subtitle: "Recent translations",
                    color: Color(hex: "#D97706")
                ) {
                    AppAnalytics.tap("home_view_history")
                    appState.currentTab = .history
                }
            }
        }
    }

    // MARK: - Supported Formats

    private var supportedFormats: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Supported Formats")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(DocumentType.allCases, id: \.self) { type in
                        FormatBadge(type: type)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Recent Documents

    private var recentDocuments: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "Recent")
                Spacer()
                Button("See All") {
                    AppAnalytics.tap("home_see_all")
                    appState.currentTab = .history
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }

            ForEach(appState.recentDocuments.prefix(3)) { doc in
                Button {
                    AppAnalytics.tap("home_open_recent", ["file": doc.fileName])
                    selectedDocument = doc
                } label: {
                    DocumentRowCard(document: doc)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Supporting Views

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundColor(.primary)
    }
}

struct QuickActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(color)
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct FormatBadge: View {
    let type: DocumentType

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: type.icon)
                .font(.system(size: 13))
            Text(type.rawValue)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(.systemGray6))
        .cornerRadius(20)
        .foregroundColor(.primary)
    }
}

struct DocumentRowCard: View {
    let document: TranslatedDocument

    var body: some View {
        HStack(spacing: 14) {
            // Thumbnail or icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: document.documentType.color).opacity(0.12))
                    .frame(width: 50, height: 60)
                if let thumb = document.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: document.documentType.icon)
                        .font(.system(size: 22))
                        .foregroundColor(Color(hex: document.documentType.color))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(document.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(document.originalLanguage.flag)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(document.targetLanguage.flag)
                    Text(document.targetLanguage.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(document.formattedDate)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}
