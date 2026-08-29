import SwiftUI
import PencilKit

struct SignStampEditorView: View {
    @State private var pages: [UIImage]
    @State private var currentPage: Int
    let documentID: UUID
    let onBrandingRemoved: (() -> Void)?
    let onComplete: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab: SignStampTab = .signature
    @State private var includeSignature = true
    @State private var includeStamp = true
    @State private var applyToAllPages = false

    @State private var signatureImage: UIImage?
    @State private var stampImage: UIImage?
    @State private var signaturePlacement = PlacedOverlay.defaultSignature
    @State private var stampPlacement = PlacedOverlay.defaultStamp
    @State private var includeDate = false
    @State private var stampDate = Date()
    @State private var dateImage: UIImage?
    @State private var datePlacement = PlacedOverlay.defaultDate
    @State private var includeSignatureLine = false
    @State private var signatureLineName = ""
    @State private var signatureLineImage: UIImage?
    @State private var signatureLinePlacement = PlacedOverlay.defaultSignatureLine

    @State private var selectedStampText = "Approved"
    @State private var customStampText = ""
    @State private var customStampColor = StampStyle.inkRed
    @State private var savedSignatures: [SavedSignature] = []
    @State private var savedStamps: [SavedStamp] = []
    @State private var previewSize: CGSize = .zero
    @State private var usingImportedStamp = false

    @State private var showFullScreenSignature = false
    @State private var showStampImport = false
    @State private var showStampDraw = false
    @State private var showStampChat = false
    @State private var selectedOverlay: OverlayKind?
    @State private var showBrandingTag: Bool
    @State private var showRemovePayment = false

    private let service = SignStampService.shared

    init(
        pages: [UIImage],
        pageIndex: Int = 0,
        documentID: UUID,
        onBrandingRemoved: (() -> Void)? = nil,
        onComplete: @escaping ([UIImage]) -> Void
    ) {
        _pages = State(initialValue: pages)
        _currentPage = State(initialValue: min(max(pageIndex, 0), max(pages.count - 1, 0)))
        self.documentID = documentID
        self.onBrandingRemoved = onBrandingRemoved
        self.onComplete = onComplete
        _showBrandingTag = State(initialValue: !BrandingStore.hasRemovedTag(for: documentID))
    }

    private var pageImage: UIImage {
        guard currentPage < pages.count else { return pages.first ?? UIImage() }
        return pages[currentPage]
    }

    var body: some View {
        NavigationView {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    documentPreview
                        .frame(height: max(160, min(geo.size.height * 0.4, 360)))
                    if pages.count > 1 {
                        pageNavigator
                    }
                    controlPanel
                }
            }
            .navigationTitle("Sign & Stamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: AppAnalytics.action("sign_cancel") { dismiss() })
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply", action: AppAnalytics.action("sign_apply") { applyAnnotations() })
                        .font(.headline)
                        .disabled(!canApply)
                }
            }
            .onAppear {
                savedSignatures = service.loadSavedSignatures()
                savedStamps = service.loadSavedStamps()
                refreshStampPreview()
                refreshDatePreview()
                refreshSignatureLinePreview()
                if stampImage != nil { selectedOverlay = .stamp }
            }
            .onChange(of: activeTab) { _, tab in
                if tab == .date {
                    includeDate = true
                    refreshDatePreview()
                    selectedOverlay = .date
                }
            }
            .fullScreenCover(isPresented: $showFullScreenSignature) {
                FullScreenSignatureView { image in
                    signatureImage = image
                    selectedOverlay = .signature
                    savedSignatures = service.loadSavedSignatures()
                }
            }
            .sheet(isPresented: $showStampImport) {
                StampImportView { image in
                    if let image {
                        stampImage = image
                        usingImportedStamp = true
                        customStampText = ""
                        selectedOverlay = .stamp
                        savedStamps = service.loadSavedStamps()
                    }
                }
            }
            .fullScreenCover(isPresented: $showStampDraw) {
                FullScreenStampDrawView { image in
                    if let image {
                        stampImage = image
                        usingImportedStamp = true
                        selectedOverlay = .stamp
                        savedStamps = service.loadSavedStamps()
                    }
                }
            }
            .sheet(isPresented: $showStampChat) {
                StampChatView { image in
                    if let image {
                        stampImage = image
                        usingImportedStamp = true
                        selectedOverlay = .stamp
                        savedStamps = service.loadSavedStamps()
                    }
                }
            }
            .sheet(isPresented: $showRemovePayment) {
                RemoveTagPaymentSheet(documentID: documentID) {
                    showBrandingTag = false
                    onBrandingRemoved?()
                }
            }
        }
    }

    // MARK: - Preview

    private var documentPreview: some View {
        GeometryReader { _ in
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                Image(uiImage: pageImage)
                    .resizable()
                    .scaledToFit()
                    .id(currentPage)
                    .background(
                        GeometryReader { imgGeo in
                            Color.clear.onAppear { previewSize = imgGeo.size }
                                .onChange(of: imgGeo.size) { previewSize = $0 }
                        }
                    )
                    .overlay {
                        if previewSize != .zero {
                            overlayLayer(in: previewSize)
                                .coordinateSpace(name: "stampCanvas")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showBrandingTag, previewSize != .zero {
                            brandingTagChip(fontSize: DocumentBranding.fontSize(for: previewSize))
                                .padding(.trailing, max(8, previewSize.width * 0.03))
                                .padding(.bottom, max(6, previewSize.height * 0.02))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if pages.count > 1 {
                            Text("Page \(currentPage + 1) of \(pages.count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var pageNavigator: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button {
                    AppAnalytics.tap("sign_prev_page")
                    goToPage(currentPage - 1)
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.title2)
                }
                .disabled(currentPage <= 0)

                Text("Page \(currentPage + 1) of \(pages.count)")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 120)

                Button {
                    AppAnalytics.tap("sign_next_page")
                    goToPage(currentPage + 1)
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title2)
                }
                .disabled(currentPage >= pages.count - 1)
            }
            .foregroundColor(.blue)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pages.indices, id: \.self) { index in
                            Button {
                                AppAnalytics.tap("sign_page_thumb", ["page": index + 1])
                                goToPage(index)
                            } label: {
                                Image(uiImage: pages[index])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 58)
                                    .clipped()
                                    .background(Color.white)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(
                                                index == currentPage ? Color.blue : Color.secondary.opacity(0.35),
                                                lineWidth: index == currentPage ? 2.5 : 1
                                            )
                                    )
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
                .onChange(of: currentPage) { _, page in
                    withAnimation { proxy.scrollTo(page, anchor: .center) }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func goToPage(_ index: Int) {
        guard pages.count > 1 else { return }
        currentPage = min(max(index, 0), pages.count - 1)
    }

    @ViewBuilder
    private func overlayLayer(in size: CGSize) -> some View {
        ZStack {
            if includeStamp, let stampImage {
                DraggableOverlay(
                    image: stampImage,
                    placement: $stampPlacement,
                    canvasSize: size,
                    tint: .red,
                    isSelected: selectedOverlay == .stamp,
                    onSelect: { selectedOverlay = .stamp }
                )
                if selectedOverlay == .stamp {
                    overlayDeleteButton(placement: stampPlacement, image: stampImage, canvasSize: size) {
                        self.stampImage = nil
                        usingImportedStamp = false
                        selectedOverlay = includeSignature && signatureImage != nil ? .signature : nil
                    }
                    overlayRotateHandle(placement: $stampPlacement, image: stampImage, canvasSize: size)
                }
            }
            if includeSignatureLine, let signatureLineImage {
                DraggableOverlay(
                    image: signatureLineImage,
                    placement: $signatureLinePlacement,
                    canvasSize: size,
                    tint: .indigo,
                    isSelected: selectedOverlay == .signatureLine,
                    onSelect: { selectedOverlay = .signatureLine }
                )
                if selectedOverlay == .signatureLine {
                    overlayDeleteButton(placement: signatureLinePlacement, image: signatureLineImage, canvasSize: size) {
                        includeSignatureLine = false
                        selectedOverlay = includeSignature && signatureImage != nil ? .signature : nil
                    }
                    overlayRotateHandle(placement: $signatureLinePlacement, image: signatureLineImage, canvasSize: size)
                }
            }
            if includeSignature, let signatureImage {
                DraggableOverlay(
                    image: signatureImage,
                    placement: $signaturePlacement,
                    canvasSize: size,
                    tint: .blue,
                    isSelected: selectedOverlay == .signature,
                    onSelect: { selectedOverlay = .signature }
                )
                if selectedOverlay == .signature {
                    overlayDeleteButton(placement: signaturePlacement, image: signatureImage, canvasSize: size) {
                        self.signatureImage = nil
                        selectedOverlay = includeStamp && stampImage != nil ? .stamp : nil
                    }
                    overlayRotateHandle(placement: $signaturePlacement, image: signatureImage, canvasSize: size)
                }
            }
            if includeDate, let dateImage {
                DraggableOverlay(
                    image: dateImage,
                    placement: $datePlacement,
                    canvasSize: size,
                    tint: .orange,
                    isSelected: selectedOverlay == .date,
                    onSelect: { selectedOverlay = .date }
                )
                if selectedOverlay == .date {
                    overlayDeleteButton(placement: datePlacement, image: dateImage, canvasSize: size) {
                        includeDate = false
                        selectedOverlay = includeStamp && stampImage != nil ? .stamp : (includeSignature && signatureImage != nil ? .signature : nil)
                    }
                    overlayRotateHandle(placement: $datePlacement, image: dateImage, canvasSize: size)
                }
            }
        }
    }

    private func brandingTagChip(fontSize: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(DocumentBranding.tag)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Button {
                AppAnalytics.tap("sign_remove_tag")
                showRemovePayment = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.red)
                    .font(.system(size: max(18, fontSize + 6)))
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Scanned by DocuTranslate tag")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.45))
        .cornerRadius(4)
    }

    private func overlayDeleteButton(
        placement: PlacedOverlay,
        image: UIImage,
        canvasSize: CGSize,
        action: @escaping () -> Void
    ) -> some View {
        let width = canvasSize.width * placement.relativeWidth
        let aspect = image.size.height / max(image.size.width, 1)
        let height = width * aspect
        let x = canvasSize.width * placement.centerX + width / 2
        let y = canvasSize.height * placement.centerY - height / 2
        return Button(action: {
            AppAnalytics.tap("sign_delete_overlay")
            action()
        }) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.red)
                .font(.system(size: 24))
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .padding(8)
        }
        .position(x: min(max(x, 18), canvasSize.width - 18), y: min(max(y, 18), canvasSize.height - 18))
        .zIndex(10)
    }

    private func overlayRotateHandle(
        placement: Binding<PlacedOverlay>,
        image: UIImage,
        canvasSize: CGSize
    ) -> some View {
        let p = placement.wrappedValue
        let width = canvasSize.width * p.relativeWidth
        let aspect = image.size.height / max(image.size.width, 1)
        let height = width * aspect
        let cx = canvasSize.width * p.centerX
        let cy = canvasSize.height * p.centerY
        let radius = hypot(width, height) / 2 + 24
        let angle = (p.rotation + 90) * .pi / 180
        let hx = (cx + CGFloat(cos(angle)) * radius).clamped(to: 16...(canvasSize.width - 16))
        let hy = (cy + CGFloat(sin(angle)) * radius).clamped(to: 16...(canvasSize.height - 16))

        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: cx, y: cy))
                path.addLine(to: CGPoint(x: hx, y: hy))
            }
            .stroke(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .allowsHitTesting(false)

            Image(systemName: "rotate.right.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.blue)
                .font(.system(size: 28))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .position(x: hx, y: hy)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("stampCanvas"))
                        .onChanged { value in
                            let dx = value.location.x - cx
                            let dy = value.location.y - cy
                            placement.wrappedValue.rotation = atan2(dy, dx) * 180 / .pi - 90
                        }
                )
        }
        .zIndex(11)
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                toggleRow
                tabPicker
                tabContent
                applyOptions
            }
        }
        .scrollIndicators(.visible)
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.08), radius: 8, y: -2)
    }

    private var toggleRow: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $includeSignature) {
                Label("Signature", systemImage: "signature")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.button)
            .tint(.blue)

            Toggle(isOn: $includeStamp) {
                Label("Stamp", systemImage: "seal.fill")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.button)
            .tint(.red)

            Toggle(isOn: $includeDate) {
                Label("Date", systemImage: "calendar")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.button)
            .tint(.orange)
            .onChange(of: includeDate) { _, on in
                if on {
                    refreshDatePreview()
                    selectedOverlay = .date
                    activeTab = .date
                } else if selectedOverlay == .date {
                    selectedOverlay = includeStamp && stampImage != nil ? .stamp : nil
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var tabPicker: some View {
        Picker("Tool", selection: $activeTab) {
            ForEach(SignStampTab.allCases) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .signature:
            signaturePanel
        case .stamp:
            stampPanel
        case .date:
            datePanel
        }
    }

    private var signaturePanel: some View {
        VStack(spacing: 12) {
            Button {
                AppAnalytics.tap("sign_draw_signature")
                showFullScreenSignature = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "pencil.and.scribble")
                        .font(.title2)
                        .foregroundColor(.blue)
                        .frame(width: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Draw Signature")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text("Opens full-screen signing pad")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.blue.opacity(0.08))
                .cornerRadius(14)
            }
            .buttonStyle(.plain)

            signatureLineCard

            if let signatureImage {
                HStack {
                    Text("Current signature")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Remove", action: AppAnalytics.action("sign_remove_signature") { self.signatureImage = nil })
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Image(uiImage: signatureImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 56)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            }

            if !savedSignatures.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved Signatures")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(savedSignatures) { saved in
                                if let img = saved.image {
                                    Button {
                                        AppAnalytics.tap("sign_saved_signature")
                                        signatureImage = img
                                    } label: {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 90, height: 44)
                                            .padding(8)
                                            .background(Color(.systemGray6))
                                            .cornerRadius(10)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 60)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private var signatureLineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $includeSignatureLine) {
                Label("Signature: _______", systemImage: "character.cursor.ibeam")
                    .font(.subheadline.weight(.medium))
            }
            .onChange(of: includeSignatureLine) { _, on in
                if on {
                    refreshSignatureLinePreview()
                    selectedOverlay = .signatureLine
                } else if selectedOverlay == .signatureLine {
                    selectedOverlay = includeSignature && signatureImage != nil ? .signature : nil
                }
            }

            if includeSignatureLine {
                TextField("Name on the line (optional)", text: $signatureLineName)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .onChange(of: signatureLineName) { _, _ in
                        refreshSignatureLinePreview()
                        selectedOverlay = .signatureLine
                    }

                if let signatureLineImage {
                    HStack {
                        Spacer()
                        Image(uiImage: signatureLineImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 32)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }

                Text("Leave the name empty for a blank SIGNATURE: _______ line, or type a name to fill it. Drag a drawn signature onto the blank.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color.indigo.opacity(0.08))
        .cornerRadius(14)
    }

    private var stampPanel: some View {
        VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        AppAnalytics.tap("sign_write_stamp")
                        showStampDraw = true
                    } label: {
                        stampActionCard(icon: "pencil.and.scribble", title: "Write Stamp", subtitle: "Type or draw CANCELLED", color: .red)
                    }
                    .buttonStyle(.plain)

                    Button {
                        AppAnalytics.tap("sign_stamp_from_photo")
                        showStampImport = true
                    } label: {
                        stampActionCard(icon: "camera.fill", title: "From Photo", subtitle: "Read stamp from image", color: .green)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    AppAnalytics.tap("sign_ai_stamp_chat")
                    showStampChat = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundColor(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Stamp Chat")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                            Text("Type or speak: company, date, color")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "mic.fill")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.08))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)

                if usingImportedStamp, stampImage != nil {
                    HStack {
                        Text("Using your custom stamp")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Use typed stamps") {
                            AppAnalytics.tap("sign_use_typed_stamps")
                            usingImportedStamp = false
                            refreshStampPreview()
                        }
                        .font(.caption)
                    }
                }

                if !savedStamps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved Stamps")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(savedStamps) { saved in
                                    if let img = saved.image {
                                        Button {
                                            AppAnalytics.tap("sign_saved_stamp", ["name": saved.name])
                                            stampImage = img
                                            usingImportedStamp = true
                                            customStampText = ""
                                            selectedOverlay = .stamp
                                        } label: {
                                            VStack(spacing: 4) {
                                                Image(uiImage: img)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 56, height: 56)
                                                    .padding(8)
                                                    .background(Color(.systemGray6))
                                                    .cornerRadius(10)
                                                Text(saved.name)
                                                    .font(.system(size: 9))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                    .frame(width: 72)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Text("Presets")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(StampStyle.presets, id: \.0) { preset in
                            Button {
                                AppAnalytics.tap("sign_stamp_preset", ["name": preset.0])
                                selectedStampText = preset.0
                                customStampText = ""
                                customStampColor = preset.1.color
                                usingImportedStamp = false
                                refreshStampPreview()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(uiImage: service.makeStamp(text: preset.0, style: preset.1))
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 56, height: 56)
                                    Text(preset.0)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(isPresetSelected(preset.0) ? .blue : .secondary)
                                }
                                .padding(8)
                                .background(
                                    isPresetSelected(preset.0)
                                        ? Color.blue.opacity(0.1) : Color(.systemGray6)
                                )
                                .cornerRadius(10)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom text")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        TextField("e.g. Cancelled", text: $customStampText)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.characters)
                            .onChange(of: customStampText) { _ in
                                usingImportedStamp = false
                                refreshStampPreview()
                            }
                        Button("Save") {
                            AppAnalytics.tap("sign_save_stamp")
                            usingImportedStamp = false
                            refreshStampPreview()
                            if let stampImage {
                                let name = currentStampName
                                service.saveStamp(stampImage, name: name)
                                savedStamps = service.loadSavedStamps()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(customStampText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack(spacing: 8) {
                        Text("Ink")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(StampStyle.inkChoices, id: \.0) { _, color in
                            Circle()
                                .fill(Color(uiColor: color))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().strokeBorder(colorsMatch(customStampColor, color) ? Color.primary : Color.clear, lineWidth: 2)
                                )
                                .onTapGesture {
                                    AppAnalytics.tap("sign_stamp_ink")
                                    customStampColor = color
                                    usingImportedStamp = false
                                    refreshStampPreview()
                                }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
    }

    private var datePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $includeDate) {
                Label("Place DATED line on the page", systemImage: "calendar")
                    .font(.subheadline.weight(.medium))
            }
            .onChange(of: includeDate) { _, on in
                if on {
                    refreshDatePreview()
                    selectedOverlay = .date
                }
            }

            DatePicker("Date", selection: $stampDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .onChange(of: stampDate) { _, _ in
                    includeDate = true
                    refreshDatePreview()
                    selectedOverlay = .date
                }

            Button {
                AppAnalytics.tap("sign_use_today_date")
                stampDate = Date()
                includeDate = true
                refreshDatePreview()
                selectedOverlay = .date
            } label: {
                Label("Use today's date", systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if let dateImage {
                HStack {
                    Spacer()
                    Image(uiImage: dateImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 36)
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(10)
            }

            Text("Drag the line onto the page. Use 1×1 or 2×2 if you want it small beside a stamp.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private func stampActionCard(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .cornerRadius(12)
    }

    private func isPresetSelected(_ name: String) -> Bool {
        !usingImportedStamp && customStampText.isEmpty && selectedStampText == name
    }

    private func colorsMatch(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        lhs.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        rhs.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return abs(r1 - r2) < 0.04 && abs(g1 - g2) < 0.04 && abs(b1 - b2) < 0.04
    }

    private var currentStampName: String {
        let typed = customStampText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed.capitalized }
        return selectedStampText
    }

    private var applyOptions: some View {
        VStack(spacing: 10) {
            if includeDate {
                HStack {
                    DatePicker("Dated", selection: $stampDate, displayedComponents: .date)
                        .font(.subheadline)
                    Button("Today") {
                        AppAnalytics.tap("sign_dated_today")
                        stampDate = Date()
                        includeDate = true
                        refreshDatePreview()
                        selectedOverlay = .date
                    }
                    .font(.caption.weight(.semibold))
                }
                .onChange(of: stampDate) { _, _ in
                    refreshDatePreview()
                    selectedOverlay = .date
                }
            }

            overlaySizeControls
            overlayRotationControls

            Text("Drag to place. Use the blue rotation handle or the buttons below to angle stamps and signatures.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Toggle(isOn: $applyToAllPages) {
                Text("Apply to all \(pages.count) pages")
                    .font(.subheadline)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
    }

    private var overlaySizeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sizeControlTitle)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                ForEach(OverlaySizePreset.allCases) { preset in
                    Button(preset.rawValue) {
                        AppAnalytics.tap("sign_overlay_size", ["size": preset.rawValue])
                        applySize(preset.relativeWidth)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(sizeMatches(preset.relativeWidth) ? Color.blue : Color(.systemGray5))
                    .foregroundColor(sizeMatches(preset.relativeWidth) ? .white : .primary)
                    .cornerRadius(8)
                }

                Spacer(minLength: 4)

                Button {
                    AppAnalytics.tap("sign_size_smaller")
                    nudgeSize(-0.02)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.bordered)

                Button {
                    AppAnalytics.tap("sign_size_larger")
                    nudgeSize(0.02)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var sizeControlTitle: String {
        switch selectedOverlay {
        case .signature: return "Signature size"
        case .signatureLine: return "Signature line size"
        case .date: return "Date size"
        default: return "Stamp size"
        }
    }

    private var overlayRotationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rotation")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(currentRotation.rounded()))°")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundColor(.blue)
            }

            Slider(value: rotationSliderBinding, in: -180...180, step: 1)

            HStack(spacing: 8) {
                Button {
                    AppAnalytics.tap("sign_rotate_left_90")
                    nudgeRotation(-90)
                } label: {
                    Label("90°", systemImage: "rotate.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)

                Button {
                    AppAnalytics.tap("sign_rotate_minus_15")
                    nudgeRotation(-15)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.bordered)

                Button {
                    AppAnalytics.tap("sign_rotate_plus_15")
                    nudgeRotation(15)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)

                Button {
                    AppAnalytics.tap("sign_rotate_right_90")
                    nudgeRotation(90)
                } label: {
                    Label("90°", systemImage: "rotate.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)

                Button("Reset") {
                    AppAnalytics.tap("sign_rotate_reset")
                    selectedPlacement()?.wrappedValue.rotation = 0
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    private var currentRotation: Double {
        selectedPlacement()?.wrappedValue.rotation ?? 0
    }

    private var rotationSliderBinding: Binding<Double> {
        Binding(
            get: { currentRotation },
            set: { selectedPlacement()?.wrappedValue.rotation = $0 }
        )
    }

    private func nudgeRotation(_ degrees: Double) {
        guard let binding = selectedPlacement() else { return }
        var next = binding.wrappedValue.rotation + degrees
        while next > 180 { next -= 360 }
        while next < -180 { next += 360 }
        binding.wrappedValue.rotation = next
    }

    // MARK: - Actions

    private var canApply: Bool {
        (includeSignature && signatureImage != nil)
            || (includeSignatureLine && signatureLineImage != nil)
            || (includeStamp && stampImage != nil)
            || (includeDate && dateImage != nil)
    }

    private func refreshDatePreview() {
        dateImage = service.makeDateLine(date: stampDate)
    }

    private func refreshSignatureLinePreview() {
        signatureLineImage = service.makeSignatureLine(name: signatureLineName)
    }

    private func selectedPlacement() -> Binding<PlacedOverlay>? {
        switch selectedOverlay {
        case .stamp: return $stampPlacement
        case .signature: return $signaturePlacement
        case .signatureLine: return $signatureLinePlacement
        case .date: return $datePlacement
        case nil: return includeStamp ? $stampPlacement : $signaturePlacement
        }
    }

    private func applySize(_ width: CGFloat) {
        selectedPlacement()?.wrappedValue.relativeWidth = width.clamped(to: 0.03...0.55)
    }

    private func nudgeSize(_ delta: CGFloat) {
        guard let binding = selectedPlacement() else { return }
        binding.wrappedValue.relativeWidth = (binding.wrappedValue.relativeWidth + delta).clamped(to: 0.03...0.55)
    }

    private func sizeMatches(_ width: CGFloat) -> Bool {
        abs((selectedPlacement()?.wrappedValue.relativeWidth ?? 0) - width) < 0.015
    }

    private func refreshStampPreview() {
        guard !usingImportedStamp else { return }
        let typed = customStampText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = typed.isEmpty ? selectedStampText : typed
        let preset = StampStyle.presets.first(where: { $0.0.compare(text, options: .caseInsensitive) == .orderedSame })?.1
        let color = typed.isEmpty ? (preset?.color ?? customStampColor) : customStampColor
        let style = StampStyle(
            color: color,
            fontSize: preset?.fontSize ?? 20,
            shape: typed.isEmpty ? (preset?.shape ?? .roundedRect) : .roundedRect
        )
        stampImage = service.makeStamp(text: text, style: style)
        selectedOverlay = .stamp
    }

    private func applyAnnotations() {
        let sig = includeSignature ? signatureImage.map {
            PlacedOverlay(image: $0, centerX: signaturePlacement.centerX, centerY: signaturePlacement.centerY,
                          relativeWidth: signaturePlacement.relativeWidth, rotation: signaturePlacement.rotation)
        } : nil
        let stamp = includeStamp ? stampImage.map {
            PlacedOverlay(image: $0, centerX: stampPlacement.centerX, centerY: stampPlacement.centerY,
                          relativeWidth: stampPlacement.relativeWidth, rotation: stampPlacement.rotation)
        } : nil
        let date = includeDate ? dateImage.map {
            PlacedOverlay(image: $0, centerX: datePlacement.centerX, centerY: datePlacement.centerY,
                          relativeWidth: datePlacement.relativeWidth, rotation: datePlacement.rotation)
        } : nil
        let signatureLine = includeSignatureLine ? signatureLineImage.map {
            PlacedOverlay(image: $0, centerX: signatureLinePlacement.centerX, centerY: signatureLinePlacement.centerY,
                          relativeWidth: signatureLinePlacement.relativeWidth, rotation: signatureLinePlacement.rotation)
        } : nil

        let indices = applyToAllPages
            ? Array(pages.indices)
            : [min(currentPage, max(pages.count - 1, 0))]

        var updated = pages
        for idx in indices where idx < updated.count {
            updated[idx] = service.composite(
                base: updated[idx],
                signature: sig,
                stamp: stamp,
                date: date,
                signatureLine: signatureLine
            )
        }

        AppAnalytics.log("sign_stamp_applied", [
            "has_signature": sig != nil ? "true" : "false",
            "has_signature_line": signatureLine != nil ? "true" : "false",
            "has_stamp": stamp != nil ? "true" : "false",
            "has_date": date != nil ? "true" : "false",
            "page_count": indices.count
        ])
        onComplete(updated)
        ReviewPromptService.shared.considerPrompt(after: "sign_stamp")
        dismiss()
    }
}

// MARK: - Draggable Overlay

private enum OverlayKind {
    case stamp, signature, signatureLine, date
}

private enum OverlaySizePreset: String, CaseIterable, Identifiable {
    case tiny = "1×1"
    case compact = "2×2"
    case small = "S"
    case medium = "M"
    case large = "L"

    var id: String { rawValue }

    var relativeWidth: CGFloat {
        switch self {
        case .tiny: return 0.04
        case .compact: return 0.075
        case .small: return 0.14
        case .medium: return 0.22
        case .large: return 0.36
        }
    }
}

private struct DraggableOverlay: View {
    let image: UIImage
    @Binding var placement: PlacedOverlay
    let canvasSize: CGSize
    let tint: Color
    var isSelected: Bool = false
    var onSelect: () -> Void = {}

    @State private var dragStart: PlacedOverlay?
    @State private var baseWidth: CGFloat?
    @State private var baseRotation: Double?

    private var overlaySize: CGSize {
        let width = canvasSize.width * placement.relativeWidth
        let aspect = image.size.height / max(image.size.width, 1)
        return CGSize(width: width, height: width * aspect)
    }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: overlaySize.width, height: overlaySize.height)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(isSelected ? 1 : 0.55), lineWidth: isSelected ? 2 : 1.5)
            )
            .rotationEffect(.degrees(placement.rotation))
            .position(
                x: canvasSize.width * placement.centerX,
                y: canvasSize.height * placement.centerY
            )
            .onTapGesture {
                AppAnalytics.tap("sign_select_overlay")
                onSelect()
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        onSelect()
                        if dragStart == nil { dragStart = placement }
                        let start = dragStart ?? placement
                        placement.centerX = (start.centerX + value.translation.width / canvasSize.width).clamped(to: 0.08...0.92)
                        placement.centerY = (start.centerY + value.translation.height / canvasSize.height).clamped(to: 0.08...0.92)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        onSelect()
                        if baseWidth == nil { baseWidth = placement.relativeWidth }
                        if let baseWidth {
                            placement.relativeWidth = (baseWidth * scale).clamped(to: 0.03...0.55)
                        }
                    }
                    .onEnded { _ in baseWidth = nil }
            )
            .simultaneousGesture(
                RotationGesture()
                    .onChanged { angle in
                        onSelect()
                        if baseRotation == nil { baseRotation = placement.rotation }
                        if let baseRotation {
                            placement.rotation = baseRotation + angle.degrees
                        }
                    }
                    .onEnded { _ in baseRotation = nil }
            )
    }
}

// MARK: - Signature Canvas

struct SignatureCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    var inkColor: UIColor

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: inkColor, width: 3)
        canvasView.backgroundColor = .white
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = PKInkingTool(.pen, color: inkColor, width: 3)
    }
}

private extension Angle {
    var degrees: Double { self.radians * 180 / .pi }
}
