import SwiftUI
import UniformTypeIdentifiers

struct TranslateView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = TranslateViewModel()
    @State private var showSignStampPrompt = false
    @State private var showSignStampEditor = false
    @State private var isExporting = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Language selector
                    languageSelector

                    // Document upload zone
                    uploadZone

                    // Text input (alternative)
                    if vm.showTextInput {
                        textInputSection
                    }

                    // Translation result
                    if let result = vm.translationResult {
                        translationResult(result)
                    }
                }
                .padding()
            }
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $vm.showFilePicker) {
                DocumentPickerView(vm: vm)
            }
            .alert("Sign & Stamp", isPresented: $showSignStampPrompt) {
                Button("Sign / Stamp", action: AppAnalytics.action("translate_prompt_sign") { showSignStampEditor = true })
                Button("Not Now", role: .cancel, action: AppAnalytics.action("translate_prompt_later") {})
            } message: {
                Text("Do you want to add a signature, stamp, or date to this translated document?")
            }
            .sheet(isPresented: $showSignStampEditor) {
                if let doc = vm.translatedDocument {
                    SignStampEditorView(
                        pages: ExportService.shared.imagesForSigning(doc, existing: vm.exportImages),
                        pageIndex: 0,
                        documentID: doc.id,
                        onBrandingRemoved: {
                            var updated = doc
                            updated.brandingRemoved = true
                            vm.translatedDocument = updated
                        }
                    ) { signed in
                        vm.exportImages = signed
                        var updated = vm.translatedDocument ?? doc
                        updated.brandingRemoved = updated.brandingRemoved == true || BrandingStore.hasRemovedTag(for: doc.id)
                        vm.translatedDocument = updated
                        appState.addDocument(updated, images: signed, signed: true)
                    }
                }
            }
            .onChange(of: vm.translationResult?.id) { _, _ in
                if let doc = vm.translationResult {
                    let pages = ExportService.shared.imagesForSigning(doc, existing: vm.exportImages)
                    appState.addDocument(doc, images: pages)
                    showSignStampPrompt = true
                }
            }
            .overlay {
                if vm.isTranslating {
                    TranslationProgressView(vm: vm)
                } else if isExporting {
                    ExportingOverlay()
                }
            }
            .alert("Error", isPresented: $vm.showError) {
                Button("OK", role: .cancel, action: AppAnalytics.action("translate_error_ok") {})
            } message: {
                Text(vm.errorMessage)
            }
            .background(AppleTranslationHook())
        }
    }

    // MARK: - Language Selector

    private var languageSelector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Source language
                LanguagePickerButton(
                    label: "From",
                    language: vm.sourceLanguage,
                    isAuto: vm.autoDetect
                ) {
                    AppAnalytics.tap("translate_source_language")
                    vm.showSourcePicker = true
                }
                .sheet(isPresented: $vm.showSourcePicker) {
                    LanguagePickerSheet(
                        title: "Source Language",
                        selection: $vm.sourceLanguage,
                        showAutoDetect: true,
                        autoDetect: $vm.autoDetect
                    )
                }

                // Swap button
                Button {
                    AppAnalytics.tap("translate_swap_languages")
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        let tmp = vm.sourceLanguage
                        vm.sourceLanguage = vm.targetLanguage
                        vm.targetLanguage = tmp
                        vm.autoDetect = false
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 8)

                // Target language
                LanguagePickerButton(
                    label: "To",
                    language: vm.targetLanguage,
                    isAuto: false
                ) {
                    AppAnalytics.tap("translate_target_language")
                    vm.showTargetPicker = true
                }
                .sheet(isPresented: $vm.showTargetPicker) {
                    LanguagePickerSheet(
                        title: "Target Language",
                        selection: $vm.targetLanguage,
                        showAutoDetect: false,
                        autoDetect: .constant(false)
                    )
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - Upload Zone

    private var uploadZone: some View {
        VStack(spacing: 16) {
            Button {
                AppAnalytics.tap("translate_upload_document")
                vm.showFilePicker = true
            } label: {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 70, height: 70)
                        Image(systemName: vm.selectedFileName != nil ? "doc.fill" : "arrow.up.doc")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.blue)
                    }

                    VStack(spacing: 4) {
                        if let name = vm.selectedFileName {
                            Text(name)
                                .font(.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text("Tap to change")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Upload Document")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("PDF, Word, Excel, PPT, Image, TXT")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            vm.selectedFileName != nil ? Color.blue : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: [8])
                        )
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(vm.selectedFileName != nil ? Color.blue.opacity(0.04) : Color(.systemGray6))
                )
            }
            .buttonStyle(.plain)

            // OR divider
            HStack {
                Rectangle().frame(height: 1).foregroundColor(.secondary.opacity(0.2))
                Text("or").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                Rectangle().frame(height: 1).foregroundColor(.secondary.opacity(0.2))
            }

            Button {
                AppAnalytics.tap(vm.showTextInput ? "translate_hide_text" : "translate_show_text")
                withAnimation { vm.showTextInput.toggle() }
            } label: {
                Label(
                    vm.showTextInput ? "Hide text input" : "Paste / type text",
                    systemImage: "text.cursor"
                )
                .font(.subheadline)
                .foregroundColor(.blue)
            }

            // Translate button
            if vm.selectedFileName != nil || !vm.inputText.isEmpty {
                Button {
                    AppAnalytics.tap("translate_start")
                    Task { await vm.translate() }
                } label: {
                    Label("Translate Document", systemImage: "wand.and.stars")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "#1a56d6"), Color(hex: "#0f3a9e")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(14)
                }
            }
        }
    }

    // MARK: - Text Input

    private var textInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text Input")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)

            TextEditor(text: $vm.inputText)
                .frame(minHeight: 140)
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .font(.body)
                .overlay(
                    Group {
                        if vm.inputText.isEmpty {
                            Text("Paste your text here...")
                                .foregroundColor(.secondary)
                                .padding(16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                )

            if !vm.inputText.isEmpty {
                HStack {
                    Text("\(vm.inputText.count) characters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Clear", action: AppAnalytics.action("translate_clear_text") { vm.inputText = "" })
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Translation Result

    private func translationResult(_ result: TranslatedDocument) -> some View {
        VStack(spacing: 12) {
            TranslatedDocumentPreview(
                document: result,
                scannedImages: ExportService.shared.imagesForSigning(result, existing: vm.exportImages),
                onSignStamp: {
                    AppAnalytics.tap("translate_sign_stamp")
                    showSignStampEditor = true
                }
            )
            ExportFormatRow(isEnabled: !isExporting) { format in
                AppAnalytics.tap("translate_export_format", ["format": format.rawValue])
                Task { await exportTranslated(result, format: format) }
            }
        }
    }

    private func exportTranslated(_ document: TranslatedDocument, format: ExportFormat) async {
        isExporting = true
        do {
            try await appState.exportAndReveal(document, format: format, images: vm.exportImages)
        } catch {
            vm.errorMessage = error.localizedDescription
            vm.showError = true
        }
        isExporting = false
    }
}

// MARK: - Language Picker Button

struct LanguagePickerButton: View {
    let label: String
    let language: Language
    let isAuto: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 5) {
                    if isAuto {
                        Image(systemName: "sparkle")
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                        Text("Auto-detect")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                    } else {
                        Text(language.flag)
                        Text(language.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Export Format Row

struct ExportFormatRow: View {
    var isEnabled: Bool = true
    let onSelect: (ExportFormat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export As")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 8) {
                ForEach(ExportFormat.allCases) { format in
                    Button {
                        onSelect(format)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: format.icon)
                                .font(.system(size: 18))
                                .foregroundColor(.blue)
                            Text(format.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                }
            }
        }
    }
}
