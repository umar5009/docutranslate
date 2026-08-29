import SwiftUI
import VisionKit
import PhotosUI

struct ScanView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ScanViewModel()

    var body: some View {
        NavigationView {
            Group {
                if vm.session.pages.isEmpty {
                    emptyState
                } else {
                    scanEditor
                }
            }
            .navigationTitle("Scan Document")
            .navigationBarTitleDisplayMode(vm.session.pages.isEmpty ? .large : .inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !vm.session.pages.isEmpty {
                        Button("Clear", action: AppAnalytics.action("scan_clear") { vm.clearSession() })
                            .foregroundColor(.red)
                    }
                    Button {
                        AppAnalytics.tap("scan_add_page")
                        vm.showActionSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .confirmationDialog("Add Page", isPresented: $vm.showActionSheet) {
                Button("Scan with Camera", action: AppAnalytics.action("scan_camera") { vm.showScanner = true })
                Button("Choose from Photos", action: AppAnalytics.action("scan_photos") { vm.showPhotoPicker = true })
                Button("Choose File", action: AppAnalytics.action("scan_file") { vm.showFilePicker = true })
                Button("Cancel", role: .cancel, action: AppAnalytics.action("scan_add_cancel") {})
            }
            .sheet(isPresented: $vm.showScanner) {
                DocumentScannerWrapper(vm: vm)
            }
            .photosPicker(isPresented: $vm.showPhotoPicker, selection: $vm.photoPickerItems, maxSelectionCount: 10)
            .sheet(isPresented: $vm.showFilePicker) {
                DocumentPickerView(vm: nil, onURL: { url in
                    Task { await vm.addFromFile(url: url) }
                })
            }
            .sheet(isPresented: $vm.showCropEditor) {
                if let idx = vm.editingPageIndex {
                    CropEditorView(vm: vm, pageIndex: idx)
                }
            }
            .sheet(isPresented: $vm.showSignStampEditor) {
                if let idx = vm.currentPageIndex {
                    SignStampEditorView(
                        pages: vm.session.pages.map(\.displayImage),
                        pageIndex: idx,
                        documentID: vm.session.id
                    ) { signed in
                        for i in signed.indices where i < vm.session.pages.count {
                            vm.session.pages[i].processedImage = signed[i]
                        }
                        vm.persistToHistory(signed: true, images: signed)
                    }
                }
            }
            .sheet(isPresented: $vm.showTranslateSheet) {
                ScanTranslateView(vm: vm)
            }
            .onChange(of: vm.photoPickerItems) { items in
                Task { await vm.loadPhotos(from: items) }
            }
            .alert("Saved", isPresented: $vm.showExportSuccess) {
                Button("OK", role: .cancel, action: AppAnalytics.action("scan_export_ok") {})
            } message: {
                Text(vm.exportSuccessMessage)
            }
            .alert("Export Failed", isPresented: $vm.showExportError) {
                Button("OK", role: .cancel, action: AppAnalytics.action("scan_export_error_ok") {})
            } message: {
                Text(vm.exportErrorMessage)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.purple.opacity(0.08))
                    .frame(width: 120, height: 120)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 52, weight: .light))
                    .foregroundColor(.purple)
            }

            VStack(spacing: 8) {
                Text("Scan Any Document")
                    .font(.title2.bold())
                Text("Use your camera, photos app, or import\na file to begin scanning")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                ScanOptionButton(
                    icon: "camera.fill",
                    title: "Scan with Camera",
                    subtitle: "Auto-detect & crop",
                    color: .purple
                ) {
                    AppAnalytics.tap("scan_camera")
                    vm.showScanner = true
                }

                ScanOptionButton(
                    icon: "photo.on.rectangle",
                    title: "Import from Photos",
                    subtitle: "Select multiple pages",
                    color: .blue
                ) {
                    AppAnalytics.tap("scan_photos")
                    vm.showPhotoPicker = true
                }

                ScanOptionButton(
                    icon: "doc.badge.arrow.up",
                    title: "Import File",
                    subtitle: "PDF, image files",
                    color: .green
                ) {
                    AppAnalytics.tap("scan_file")
                    vm.showFilePicker = true
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    // MARK: - Scan Editor (pages loaded)

    private var scanEditor: some View {
        VStack(spacing: 0) {
            pagePreviewArea
            editorToolPanel
            editorBottomBar
            editorActionBar
        }
        .background(Color(.systemGroupedBackground))
    }

    private var pagePreviewArea: some View {
        VStack(spacing: 0) {
            if let idx = vm.currentPageIndex, idx < vm.session.pages.count {
                let page = vm.session.pages[idx]

                ZStack {
                    Color.black.opacity(0.92)

                    Image(uiImage: page.displayImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)

                    VStack {
                        HStack {
                            if page.wasEnhanced && page.processedImage != nil {
                                Label("Enhanced", systemImage: "sparkles")
                                    .font(.caption2.weight(.bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.green.opacity(0.85))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            Button {
                                AppAnalytics.tap("scan_toggle_preview")
                                vm.toggleBeforeAfter()
                            } label: {
                                Image(systemName: "eye")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.white.opacity(0.18))
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        Spacer()
                    }
                }
                .frame(maxHeight: .infinity)
            }

            pageThumbnailStrip
        }
    }

    private var pageThumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(vm.session.pages.indices, id: \.self) { idx in
                    let page = vm.session.pages[idx]
                    Button {
                        AppAnalytics.tap("scan_select_page", ["page": idx + 1])
                        vm.currentPageIndex = idx
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: page.displayImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 52, height: 72)
                                .clipped()
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(
                                            vm.currentPageIndex == idx ? Color.blue : Color.white.opacity(0.3),
                                            lineWidth: vm.currentPageIndex == idx ? 2.5 : 1
                                        )
                                )

                            Text("\(idx + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(3)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Circle())
                                .padding(3)
                        }
                    }
                }

                Button {
                    AppAnalytics.tap("scan_add_page")
                    vm.showActionSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .frame(width: 52, height: 72)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var editorToolPanel: some View {
        switch vm.editorTab {
        case .filters:
            filterScrollPanel
        case .adjust:
            adjustPanel
        case .rotate, .delete:
            EmptyView()
        }
    }

    private var filterScrollPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Filters")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Swipe for \(ScanFilter.allCases.count) styles →")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 10) {
                        ForEach(ScanFilter.clarityFirst) { filter in
                            FilterChip(
                                filter: filter,
                                isSelected: vm.session.filter == filter
                            ) {
                                AppAnalytics.tap("scan_filter", ["filter": filter.rawValue])
                                vm.applyFilter(filter)
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(filter.id, anchor: .center)
                                }
                            }
                            .id(filter.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
                .frame(height: 88)
            }
            .onAppear {
                // Scroll to current filter when panel opens
            }
        }
        .background(Color(.systemBackground))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var adjustPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Adjust")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Crop") {
                    AppAnalytics.tap("scan_crop")
                    if let idx = vm.currentPageIndex {
                        vm.editingPageIndex = idx
                        vm.showCropEditor = true
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            VStack(spacing: 8) {
                Toggle(isOn: $vm.session.autoEnhance) {
                    Label("Auto Deblur & Sharpen", systemImage: "sparkles")
                        .font(.subheadline)
                }
                .tint(.green)
                .onChange(of: vm.session.autoEnhance) { _ in vm.reapplyFilter() }

                if vm.session.autoEnhance {
                    SliderRow(label: "Sharpness", value: $vm.session.sharpness, range: 0.2...1.0) {
                        vm.reapplyFilter()
                    }
                }

                SliderRow(label: "Brightness", value: $vm.session.brightness, range: -1...1) {
                    vm.reapplyFilter()
                }
                SliderRow(label: "Contrast", value: $vm.session.contrast, range: -0.5...0.5) {
                    vm.reapplyFilter()
                }

                Button {
                    AppAnalytics.tap("scan_enhance_now")
                    vm.enhanceCurrentPage()
                } label: {
                    Label("Enhance Now", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.12))
                        .foregroundColor(.green)
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(Color(.systemBackground))
    }

    private var editorBottomBar: some View {
        HStack(spacing: 0) {
            ForEach(ScanEditorTab.allCases) { tab in
                Button {
                    AppAnalytics.tap("scan_editor_tab", ["tab": tab.rawValue])
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        switch tab {
                        case .rotate, .delete:
                            handleEditorTabAction(tab)
                        case .adjust, .filters:
                            vm.editorTab = tab
                        }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(vm.editorTab == tab ? .blue : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private func handleEditorTabAction(_ tab: ScanEditorTab) {
        guard let idx = vm.currentPageIndex else { return }
        switch tab {
        case .adjust:
            if let idx = vm.currentPageIndex {
                vm.editingPageIndex = idx
                vm.showCropEditor = true
            }
        case .rotate:
            vm.rotatePage(at: idx)
        case .delete:
            vm.deletePage(at: idx)
        case .filters:
            break
        }
    }

    private var editorActionBar: some View {
        VStack(spacing: 10) {
            Button {
                AppAnalytics.tap("scan_sign_stamp")
                vm.showSignStampEditor = true
            } label: {
                Label("Sign & Stamp", systemImage: "signature")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.purple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(12)
            }

            HStack(spacing: 12) {
                Button {
                    AppAnalytics.tap("scan_translate")
                    vm.showTranslateSheet = true
                } label: {
                    Label("Translate", systemImage: "globe")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .cornerRadius(14)
                }

                Button {
                    AppAnalytics.tap("scan_export")
                    vm.showExportOptions = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(14)
                }
                .confirmationDialog("Export As", isPresented: $vm.showExportOptions) {
                    ForEach(ExportFormat.allCases) { fmt in
                        Button(fmt.rawValue, action: AppAnalytics.action("scan_export_format", ["format": fmt.rawValue]) {
                            Task { await vm.export(as: fmt) }
                        })
                    }
                    Button("Cancel", role: .cancel, action: AppAnalytics.action("scan_export_cancel") {})
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let filter: ScanFilter
    let isSelected: Bool
    let action: () -> Void

    private var accent: Color { Color(hex: filter.accentHex) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? accent.opacity(0.25) : Color(.systemGray5))
                        .frame(width: 36, height: 28)
                    Image(systemName: filter.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isSelected ? accent : .primary)
                }

                Text(filter.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isSelected ? accent : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(filter.subtitle)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 76, height: 72)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? accent.opacity(0.1) : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isSelected)
    }
}

// MARK: - Slider Row

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 75, alignment: .leading)
            Slider(value: $value, in: range, step: 0.05)
                .tint(.blue)
                .onChange(of: value) { _ in onChange() }
            Text(String(format: "%.0f%%", value * 100))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - Scan Option Button

struct ScanOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.12))
                        .frame(width: 50, height: 50)
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(Color(.systemBackground))
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}
