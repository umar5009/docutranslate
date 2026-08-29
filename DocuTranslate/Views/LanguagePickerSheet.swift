import SwiftUI

struct LanguagePickerSheet: View {
    let title: String
    @Binding var selection: Language
    let showAutoDetect: Bool
    @Binding var autoDetect: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showingAll = false

    private var filteredLanguages: [Language] {
        if searchText.isEmpty {
            return Language.all
        }
        return Language.all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.nativeName.localizedCaseInsensitiveContains(searchText) ||
            $0.code.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            List {
                // Auto-detect option
                if showAutoDetect {
                    Section {
                        Button {
                            AppAnalytics.tap("language_auto_detect")
                            autoDetect = true
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue.opacity(0.12))
                                        .frame(width: 38, height: 38)
                                    Image(systemName: "sparkle")
                                        .font(.system(size: 16))
                                        .foregroundColor(.blue)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Auto-detect")
                                        .font(.body.weight(.medium))
                                        .foregroundColor(.primary)
                                    Text("Detect language automatically")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if autoDetect {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Popular languages
                if searchText.isEmpty {
                    Section("Popular Languages") {
                        ForEach(Language.popular) { lang in
                            LanguageRow(lang: lang, isSelected: !autoDetect && selection == lang) {
                                AppAnalytics.tap("language_select", ["code": lang.code, "name": lang.name])
                                selection = lang
                                autoDetect = false
                                dismiss()
                            }
                        }
                    }

                    Section("All Languages (\(Language.all.count))") {
                        ForEach(Language.all) { lang in
                            LanguageRow(lang: lang, isSelected: !autoDetect && selection == lang) {
                                AppAnalytics.tap("language_select", ["code": lang.code, "name": lang.name])
                                selection = lang
                                autoDetect = false
                                dismiss()
                            }
                        }
                    }
                } else {
                    Section("Results (\(filteredLanguages.count))") {
                        ForEach(filteredLanguages) { lang in
                            LanguageRow(lang: lang, isSelected: !autoDetect && selection == lang) {
                                AppAnalytics.tap("language_select", ["code": lang.code, "name": lang.name])
                                selection = lang
                                autoDetect = false
                                dismiss()
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer, prompt: "Search languages...")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: AppAnalytics.action("language_cancel") { dismiss() })
                }
            }
        }
    }
}

// MARK: - Language Row

struct LanguageRow: View {
    let lang: Language
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(lang.flag)
                    .font(.title2)
                    .frame(width: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(lang.name)
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(lang.nativeName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(lang.code.uppercased())
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.systemGray5))
                    .cornerRadius(6)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
