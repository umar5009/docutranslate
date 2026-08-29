import SwiftUI
import PhotosUI

struct ConvertView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ConvertViewModel()
    @State private var showSignStampPrompt = false
    @State private var showSignStampEditor = false
    @State private var showExport = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if vm.hasSource {
                        sourceCard
                        formatPicker
                        convertButton
                    } else {
                        uploadZone
                    }

                    if let doc = vm.processedDocument {
                        processedCard(doc)
                    }
                }
                .padding()
            }
            .navigationTitle("Convert")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if vm.hasSource {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear", action: AppAnalytics.action("convert_clear") { vm.reset() })
                    }
                }
            }
            .sheet(isPresented: $vm.showFilePicker) {
                DocumentPickerView { url in
                    Task { await vm.loadFile(url: url) }
                }
            }
            .sheet(isPresented: $showSignStampEditor) {
                if let doc = vm.processedDocument {
                    SignStampEditorView(
                        pages: ExportService.shared.imagesForSigning(doc, existing: vm.pages, preferExisting: true),
                        pageIndex: 0,
                        documentID: doc.id,
                        onBrandingRemoved: {
                            var updated = doc
                            updated.brandingRemoved = true
                            vm.processedDocument = updated
                        }
                    ) { signed in
                        vm.pages = signed
                        var updated = vm.processedDocument ?? doc
                        updated.brandingRemoved = updated.brandingRemoved == true || BrandingStore.hasRemovedTag(for: doc.id)
                        vm.processedDocument = updated
                        appState.addDocument(updated, images: signed, signed: true)
                        showExport = true
                    }
                }
            }
            .sheet(isPresented: $showExport) {
                if let doc = vm.processedDocument {
                    ExportView(document: doc, images: vm.pages, initialFormat: vm.outputFormat)
                }
            }
            .alert("Sign & Stamp?", isPresented: $showSignStampPrompt) {
                Button("Sign / Stamp", action: AppAnalytics.action("convert_prompt_sign") { showSignStampEditor = true })
                Button("Download", action: AppAnalytics.action("convert_prompt_download") { showExport = true })
                Button("Cancel", role: .cancel, action: AppAnalytics.action("convert_prompt_cancel") {})
            } message: {
                Text("Add a signature, stamp, or date before saving, or download the converted document as-is.")
            }
            .alert("Error", isPresented: $vm.showError) {
                Button("OK", role: .cancel, action: AppAnalytics.action("convert_error_ok") {})
            } message: {
                Text(vm.errorMessage)
            }
            .onChange(of: vm.photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await vm.loadPhotos() }
            }
            .overlay {
                if vm.isProcessing {
                    processingOverlay
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Change any file into PDF, Word, Excel, or images. Then sign it, or just download.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var uploadZone: some View {
        VStack(spacing: 16) {
            Button {
                AppAnalytics.tap("convert_choose_document")
                vm.showFilePicker = true
            } label: {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    Text("Choose a document")
                        .font(.headline)
                    Text("PDF, Word, Excel, PowerPoint, or images")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(Color(.systemGray6))
                .cornerRadius(20)
            }
            .buttonStyle(.plain)

            PhotosPicker(selection: $vm.photoItems, maxSelectionCount: 20, matching: .images) {
                Label("Import photos", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(14)
            }
            .simultaneousGesture(TapGesture().onEnded {
                AppAnalytics.tap("convert_import_photos")
            })
        }
    }

    private var sourceCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: vm.documentType.color).opacity(0.12))
                    .frame(width: 52, height: 64)
                if let thumb = vm.pages.first {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: vm.documentType.icon)
                        .font(.system(size: 22))
                        .foregroundColor(Color(hex: vm.documentType.color))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.selectedFileName ?? "Document")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(vm.pageCount) page(s) · \(vm.documentType.rawValue) · \(vm.fileSize)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert to")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ExportFormat.allCases) { format in
                    Button {
                        AppAnalytics.tap("convert_format", ["format": format.rawValue])
                        vm.outputFormat = format
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: format.icon)
                                .font(.system(size: 22))
                                .foregroundColor(vm.outputFormat == format ? .white : .blue)
                            Text(format.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(vm.outputFormat == format ? .white : .primary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(vm.outputFormat == format ? Color.blue : Color(.systemGray6))
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var convertButton: some View {
        Button {
            AppAnalytics.tap("convert_start", ["format": vm.outputFormat.rawValue])
            Task {
                await vm.convert()
                if let doc = vm.processedDocument {
                    appState.addDocument(doc, images: vm.pages)
                    showSignStampPrompt = true
                }
            }
        } label: {
            Label("Convert to \(vm.outputFormat.rawValue)", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.blue)
                .cornerRadius(14)
        }
        .disabled(vm.isProcessing)
    }

    private func processedCard(_ doc: TranslatedDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Ready to save")
                    .font(.headline)
                Spacer()
                Text(vm.outputFormat.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.blue)
            }

            if let preview = DocumentBranding.apply(vm.pages, to: doc).first {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Text("\(doc.pageCount) page(s) converted to \(vm.outputFormat.rawValue). Sign and stamp it first, or download it now.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            RemoveBrandingBanner(document: Binding(
                get: { vm.processedDocument ?? doc },
                set: { vm.processedDocument = $0 }
            )) { updated in
                appState.addDocument(updated, images: vm.pages, signed: updated.wasSigned == true)
            }

            Button {
                AppAnalytics.tap("convert_sign_stamp")
                showSignStampEditor = true
            } label: {
                Label("Sign / Stamp", systemImage: "signature")
                    .font(.headline)
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue.opacity(0.12))
                    .cornerRadius(14)
            }

            Button {
                AppAnalytics.tap("convert_download")
                showExport = true
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .cornerRadius(14)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(.white).scaleEffect(1.2)
                Text("Converting…")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
        }
    }
}
