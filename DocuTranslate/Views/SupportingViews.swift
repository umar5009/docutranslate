import SwiftUI
import VisionKit
import UniformTypeIdentifiers

// MARK: - Translation Progress Overlay

struct TranslationProgressView: View {
    @ObservedObject var vm: TranslateViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.12)).frame(width: 80, height: 80)
                    Image(systemName: stepIcon)
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(.blue)
                }
                VStack(spacing: 6) {
                    Text(vm.currentStep.rawValue).font(.headline)
                    Text("Please wait…").font(.subheadline).foregroundColor(.secondary)
                }
                VStack(spacing: 6) {
                    ProgressView(value: vm.translationProgress)
                        .progressViewStyle(.linear).tint(.blue).frame(width: 220)
                    Text("\(Int(vm.translationProgress * 100))%")
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach(TranslationStep.allCases, id: \.self) { step in
                        Circle()
                            .fill(step == vm.currentStep ? Color.blue :
                                  step.progress <= vm.translationProgress ? Color.blue.opacity(0.4) : Color.secondary.opacity(0.2))
                            .frame(width: step == vm.currentStep ? 10 : 6,
                                   height: step == vm.currentStep ? 10 : 6)
                            .animation(.spring(), value: vm.currentStep)
                    }
                }
            }
            .padding(32)
            .background(RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial))
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        }
    }

    private var stepIcon: String {
        switch vm.currentStep {
        case .uploading:   return "arrow.up.doc"
        case .extracting:  return "text.viewfinder"
        case .detecting:   return "globe"
        case .translating: return "wand.and.stars"
        case .formatting:  return "textformat"
        case .rendering:   return "doc.richtext"
        case .complete:    return "checkmark.circle"
        }
    }
}

// MARK: - Export View

struct ExportView: View {
    let document: TranslatedDocument
    var images: [UIImage] = []
    var initialFormat: ExportFormat = .pdf
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var liveDocument: TranslatedDocument
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var selectedFormat: ExportFormat = .pdf

    init(document: TranslatedDocument, images: [UIImage] = [], initialFormat: ExportFormat = .pdf) {
        self.document = document
        self.images = images
        self.initialFormat = initialFormat
        _liveDocument = State(initialValue: document)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                documentCard
                RemoveBrandingBanner(document: $liveDocument) { updated in
                    appState.addDocument(updated, images: images, signed: updated.wasSigned == true)
                }
                .padding(.horizontal)
                saveLocationHint
                formatGrid
                Spacer()
                exportButton
            }
            .navigationTitle("Export Document")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { selectedFormat = initialFormat }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: AppAnalytics.action("export_cancel") { dismiss() })
                }
            }
            .alert("Export Failed", isPresented: .init(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) { Button("OK", role: .cancel, action: AppAnalytics.action("export_error_ok") {}) }
            message: { Text(exportError ?? "") }
            .overlay {
                if isExporting {
                    ExportingOverlay()
                }
            }
        }
    }

    private var saveLocationHint: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedFormat.isImage ? "photo.on.rectangle.angled" : "folder.fill")
                .foregroundColor(selectedFormat.isImage ? .pink : .blue)
            Text(selectedFormat.isImage
                 ? (images.count > 1
                    ? "Each of the \(images.count) pages saves as a separate image in Photos → Recents"
                    : "Images save to the Photos app → Recents")
                 : "Documents save to Files → On My iPhone → DocuTranslate → Exports")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
    }

    private var documentCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: document.documentType.color).opacity(0.12))
                    .frame(width: 56, height: 70)
                Image(systemName: document.documentType.icon)
                    .font(.system(size: 26))
                    .foregroundColor(Color(hex: document.documentType.color))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(document.fileName).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    Text(document.originalLanguage.flag)
                    Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                    Text(document.targetLanguage.flag)
                    Text(document.targetLanguage.name).font(.subheadline).foregroundColor(.secondary)
                }
                Text("\(document.pageCount) page(s) · \(document.fileSize)").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal)
    }

    private var formatGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose Format").font(.headline).padding(.horizontal)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(ExportFormat.allCases) { fmt in
                    ExportFormatCard(format: fmt, isSelected: selectedFormat == fmt) {
                        AppAnalytics.tap("export_format", ["format": fmt.rawValue])
                        selectedFormat = fmt
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var exportButton: some View {
        Button {
            AppAnalytics.tap("export_save", ["format": selectedFormat.rawValue])
            Task { await doExport() }
        } label: {
            Group {
                if isExporting {
                    ProgressView().tint(.white)
                } else {
                    Label(
                        selectedFormat.isImage ? "Save to Photos" : "Save to Files",
                        systemImage: selectedFormat.isImage ? "photo.badge.arrow.down" : "folder.badge.plus"
                    )
                    .font(.headline)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.blue)
            .cornerRadius(14)
        }
        .disabled(isExporting)
        .padding()
    }

    private func doExport() async {
        isExporting = true
        do {
            let result = try await ExportService.shared.exportAndSave(
                document: liveDocument,
                as: selectedFormat,
                scannedImages: images.isEmpty ? nil : images
            )
            appState.addDocument(liveDocument, images: images, signed: liveDocument.wasSigned == true)
            isExporting = false
            dismiss()
            appState.revealSavedDocument(liveDocument, export: result)
        } catch {
            exportError = error.localizedDescription
            isExporting = false
        }
    }
}

// MARK: - Export Format Card

struct ExportFormatCard: View {
    let format: ExportFormat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: format.icon)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .white : .blue)
                Text(format.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isSelected ? Color.blue : Color(.systemGray6))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - Saved export alert

struct SavedExportAlert: View {
    let result: ExportService.SavedExport
    let onOK: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onOK)

            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
                    .accessibilityHidden(true)

                Text(result.userMessage)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text(result.detailMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: onOK) {
                    Text("OK")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.systemGray5))
                        .cornerRadius(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            .padding(.horizontal, 36)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture { } // keep taps on the card from hitting the dimmer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("\(result.userMessage). \(result.detailMessage)")
    }
}

struct ExportingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(.white).scaleEffect(1.2)
                Text("Saving…")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
        }
    }
}

// MARK: - Scan → Translate Sheet

struct ScanTranslateView: View {
    @ObservedObject var vm: ScanViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var tvm = TranslateViewModel()
    @State private var extracting = false
    @State private var showSignStampPrompt = false
    @State private var showSignStampEditor = false
    @State private var isExporting = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    langSelector

                    if let result = tvm.translationResult {
                        TranslatedDocumentPreview(
                            document: result,
                            scannedImages: ExportService.shared.imagesForSigning(
                                result,
                                existing: vm.session.pages.map(\.displayImage)
                            ),
                            onSignStamp: {
                                AppAnalytics.tap("scan_translate_sign")
                                showSignStampEditor = true
                            }
                        )
                        ExportFormatRow(isEnabled: !isExporting) { format in
                            AppAnalytics.tap("scan_translate_export_format", ["format": format.rawValue])
                            Task { await exportTranslated(result, format: format) }
                        }
                    } else if extracting || tvm.isTranslating {
                        translatingPlaceholder
                    }
                }
                .padding()
            }
            .navigationTitle("Translate Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel", action: AppAnalytics.action("scan_translate_cancel") { dismiss() }) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    AppAnalytics.tap("scan_translate_start")
                    Task {
                        extracting = true
                        tvm.inputText = await vm.extractAllText()
                        await tvm.translate()
                        if var doc = tvm.translationResult {
                            doc.documentType = .scanned
                            doc.pageCount = vm.session.pages.count
                            doc.fileName = "Scanned_Document"
                            tvm.translationResult = doc
                            tvm.translatedDocument = doc
                            let translatedPages = ExportService.shared.imagesForSigning(
                                doc,
                                existing: vm.session.pages.map(\.displayImage)
                            )
                            appState.addDocument(doc, images: translatedPages)
                            showSignStampPrompt = true
                        }
                        extracting = false
                    }
                } label: {
                    Group {
                        if extracting || tvm.isTranslating {
                            ProgressView().tint(.white)
                        } else {
                            Label(
                                tvm.translationResult == nil ? "Extract & Translate" : "Re-translate",
                                systemImage: "wand.and.stars"
                            )
                            .font(.headline)
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue)
                    .cornerRadius(14)
                }
                .disabled(extracting || tvm.isTranslating)
                .padding()
                .background(.ultraThinMaterial)
            }
            .overlay {
                if tvm.isTranslating {
                    TranslationProgressView(vm: tvm)
                } else if isExporting {
                    ExportingOverlay()
                }
            }
            .alert("Error", isPresented: $tvm.showError) {
                Button("OK", role: .cancel, action: AppAnalytics.action("scan_translate_error_ok") {})
            } message: {
                Text(tvm.errorMessage)
            }
            .alert("Sign & Stamp", isPresented: $showSignStampPrompt) {
                Button("Sign / Stamp", action: AppAnalytics.action("scan_translate_prompt_sign") { showSignStampEditor = true })
                Button("Not Now", role: .cancel, action: AppAnalytics.action("scan_translate_prompt_later") {})
            } message: {
                Text("Do you want to add a signature, stamp, or date to this translated document?")
            }
            .sheet(isPresented: $showSignStampEditor) {
                if let doc = tvm.translatedDocument {
                    SignStampEditorView(
                        pages: ExportService.shared.imagesForSigning(
                            doc,
                            existing: vm.session.pages.map(\.displayImage)
                        ),
                        pageIndex: 0,
                        documentID: doc.id,
                        onBrandingRemoved: {
                            var updated = doc
                            updated.brandingRemoved = true
                            tvm.translatedDocument = updated
                        }
                    ) { signed in
                        for i in signed.indices where i < vm.session.pages.count {
                            vm.session.pages[i].processedImage = signed[i]
                        }
                        var updated = tvm.translatedDocument ?? doc
                        updated.brandingRemoved = updated.brandingRemoved == true || BrandingStore.hasRemovedTag(for: doc.id)
                        tvm.translatedDocument = updated
                        appState.addDocument(updated, images: signed, signed: true)
                    }
                }
            }
            .background(AppleTranslationHook())
        }
    }

    private func exportTranslated(_ document: TranslatedDocument, format: ExportFormat) async {
        isExporting = true
        do {
            try await appState.exportAndReveal(
                document,
                format: format,
                images: vm.session.pages.map(\.displayImage)
            )
            dismiss()
        } catch {
            tvm.errorMessage = error.localizedDescription
            tvm.showError = true
        }
        isExporting = false
    }

    private var translatingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Extracting text from \(vm.session.pages.count) page(s)…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var langSelector: some View {
        HStack(spacing: 16) {
            LanguagePickerButton(label: "From", language: tvm.sourceLanguage, isAuto: tvm.autoDetect) {
                AppAnalytics.tap("scan_translate_source")
                tvm.showSourcePicker = true
            }
            .sheet(isPresented: $tvm.showSourcePicker) {
                LanguagePickerSheet(title: "Source Language", selection: $tvm.sourceLanguage,
                                    showAutoDetect: true, autoDetect: $tvm.autoDetect)
            }
            Image(systemName: "arrow.right").foregroundColor(.secondary)
            LanguagePickerButton(label: "To", language: tvm.targetLanguage, isAuto: false) {
                AppAnalytics.tap("scan_translate_target")
                tvm.showTargetPicker = true
            }
            .sheet(isPresented: $tvm.showTargetPicker) {
                LanguagePickerSheet(title: "Target Language", selection: $tvm.targetLanguage,
                                    showAutoDetect: false, autoDetect: .constant(false))
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Document Picker (UIKit bridge)

struct DocumentPickerView: UIViewControllerRepresentable {
    var vm: TranslateViewModel?
    var onURL: ((URL) -> Void)?

    private var types: [UTType] {
        [.pdf, .text, .plainText, .image, .jpeg, .png, .heic,
         UTType(filenameExtension: "docx") ?? .data,
         UTType(filenameExtension: "doc")  ?? .data,
         UTType(filenameExtension: "xlsx") ?? .data,
         UTType(filenameExtension: "csv")  ?? .data,
         UTType(filenameExtension: "pptx") ?? .data,
         UTType(filenameExtension: "txt")  ?? .data,
         UTType(filenameExtension: "rtf")  ?? .data,
         UTType(filenameExtension: "md")   ?? .data,
         UTType(filenameExtension: "svg")  ?? .data,
         UTType(filenameExtension: "xml")  ?? .data,
        ]
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(vm: vm, onURL: onURL) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let vm: TranslateViewModel?; let onURL: ((URL) -> Void)?
        init(vm: TranslateViewModel?, onURL: ((URL) -> Void)?) { self.vm = vm; self.onURL = onURL }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            vm?.fileSelected(url: url)
            onURL?(url)
        }
    }
}

// MARK: - VisionKit Document Scanner

struct DocumentScannerWrapper: UIViewControllerRepresentable {
    @ObservedObject var vm: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(vm: vm, dismiss: dismiss) }

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let vm: ScanViewModel; let dismiss: DismissAction
        init(vm: ScanViewModel, dismiss: DismissAction) { self.vm = vm; self.dismiss = dismiss }

        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            Task { @MainActor in
                for i in 0..<scan.pageCount { await vm.addPage(image: scan.imageOfPage(at: i)) }
                vm.editorTab = .filters
                dismiss()
            }
        }
        func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) { dismiss() }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFailWithError e: Error) { dismiss() }
    }
}
