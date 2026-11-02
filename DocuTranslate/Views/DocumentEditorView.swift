import SwiftUI
import PhotosUI

struct DocumentEditorView: View {
    @State private var pages: [UIImage]
    @State private var currentPage: Int
    let fileName: String
    let onComplete: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var mode: DocumentEditorMode
    @State private var editTool: EditTool = .select
    @State private var markupTool: MarkupTool = .highlight
    @State private var shapeKind: EditorShapeKind = .rectangle
    @State private var elements: [EditorElement] = []
    @State private var selectedID: UUID?
    @State private var undoStack: [[EditorElement]] = []
    @State private var redoStack: [[EditorElement]] = []
    @State private var canvasSize: CGSize = .zero
    @State private var draftRect: CGRect?
    @State private var draftPoints: [CGPoint] = []
    @State private var ocrPages: Set<Int> = []
    @State private var nextZ = 1
    @State private var markupColor = DocumentEditorPalette.markupColors[0]
    @State private var photoItem: PhotosPickerItem?
    @State private var showImagePicker = false
    @State private var showShapePicker = false
    @State private var showFontPicker = false
    @State private var showLinkAlert = false
    @State private var pendingLinkRect: CGRect?
    @State private var linkURL = "https://"
    @State private var isSaving = false
    @State private var isRecognizing = false
    @State private var movingStart: CGRect?
    @State private var showDiscardAlert = false
    @State private var inspectorExpanded = false
    @State private var formFields: [DetectedFormField] = []
    @State private var pendingField: DetectedFormField?
    @State private var showDatePicker = false
    @State private var pickedDate = Date()
    @State private var showSignatureCapture = false
    @State private var zoomScale: CGFloat = 1
    @State private var zoomResetToken = 0
    @State private var zoomFocusToken = 0
    @State private var zoomFocusRect: CGRect?
    @State private var keyboardHeight: CGFloat = 0
    @State private var resizeStart: CGRect?
    @State private var resizeStartFont: CGFloat = 0
    @State private var isPinchingBox = false
    @State private var zoomRequest: CGFloat = 1
    @State private var zoomRequestToken = 0
    @State private var lensMode = false
    @State private var rangeAnchorID: UUID?
    @State private var rangeFocusID: UUID?
    @State private var rangeAwaitingEnd = false
    @State private var ignoreSelectTapUntil = Date.distantPast
    @State private var lastPrintedTap: (id: UUID, time: Date)?

    init(
        pages: [UIImage],
        pageIndex: Int = 0,
        fileName: String,
        initialMode: DocumentEditorMode = .edit,
        onComplete: @escaping ([UIImage]) -> Void
    ) {
        _pages = State(initialValue: pages)
        _currentPage = State(initialValue: min(max(pageIndex, 0), max(pages.count - 1, 0)))
        self.fileName = fileName
        self.onComplete = onComplete
        _mode = State(initialValue: initialMode)
        if initialMode == .markup {
            _markupTool = State(initialValue: .highlight)
        }
    }

    private var pageImage: UIImage {
        guard currentPage < pages.count else { return pages.first ?? UIImage() }
        return pages[currentPage]
    }

    private var pageElements: [EditorElement] {
        elements.filter { $0.pageIndex == currentPage }.sorted { lhs, rhs in
            if lhs.id == selectedID { return false }
            if rhs.id == selectedID { return true }
            return lhs.zIndex < rhs.zIndex
        }
    }

    private var selected: EditorElement? {
        elements.first { $0.id == selectedID }
    }

    private var selectedIndex: Int? {
        elements.firstIndex { $0.id == selectedID }
    }

    private var pageChanges: [EditorElement] {
        pageElements.filter { $0.changeLabel != nil && ($0.kind != .existingText || $0.isModified) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if mode == .edit {
                editToolbar
            } else {
                markupToolbar
            }
            zoomBar
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            bottomChrome
        }
        .padding(.bottom, keyboardHeight)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .photosPicker(isPresented: $showImagePicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            Task { await addPickedImage(item) }
        }
        .confirmationDialog("Shape", isPresented: $showShapePicker, titleVisibility: .visible) {
            ForEach(EditorShapeKind.allCases) { kind in
                Button(kind.title) {
                    AppAnalytics.tap("editor_shape", ["shape": kind.rawValue])
                    shapeKind = kind
                    editTool = .shape
                }
            }
            Button("Cancel", role: .cancel, action: AppAnalytics.action("editor_shape_cancel") {})
        }
        .alert("Add Link", isPresented: $showLinkAlert) {
            TextField("https://", text: $linkURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            Button("Add", action: AppAnalytics.action("editor_link_add") { commitLink() })
            Button("Cancel", role: .cancel, action: AppAnalytics.action("editor_link_cancel") { pendingLinkRect = nil })
        } message: {
            Text("Enter a web address for this link box.")
        }
        .sheet(isPresented: $showFontPicker) {
            fontPicker
        }
        .sheet(isPresented: $showDatePicker) {
            datePickerSheet
        }
        .fullScreenCover(isPresented: $showSignatureCapture) {
            FullScreenSignatureView { image in
                if let image {
                    insertSignature(image)
                }
                pendingField = nil
            }
        }
        .alert("Discard Changes?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive, action: AppAnalytics.action("editor_discard") { dismiss() })
            Button("Keep Editing", role: .cancel, action: AppAnalytics.action("editor_keep_editing") {})
        } message: {
            Text("Your edits on this document will be lost.")
        }
        .overlay {
            if isSaving || isRecognizing {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(isSaving ? "Saving…" : "Reading text…")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .task { await recognizeCurrentPage() }
        .onChange(of: currentPage) { _, _ in
            selectedID = nil
            rangeAnchorID = nil
            rangeFocusID = nil
            rangeAwaitingEnd = false
            zoomScale = 1
            zoomResetToken += 1
            zoomFocusRect = nil
            Task { await recognizeCurrentPage() }
        }
        .onChange(of: selectedID) { _, _ in
            if let item = selected, item.isText, item.kind != .existingText {
                focusOnNormalizedRect(visibleEditRect(for: item))
            }
        }
        .onChange(of: keyboardHeight) { old, new in
            if old < 50, new >= 50, let item = selected, item.isText, item.kind != .existingText {
                inspectorExpanded = false
                focusOnNormalizedRect(visibleEditRect(for: item))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardHeight = 0 }
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        if let item = selected, item.isText {
            EditTextPanel(
                element: item,
                expanded: $inspectorExpanded,
                changeSummary: pageChanges.last?.changeDetail,
                onChange: updateSelected,
                onCopy: copySelected,
                onFront: bringToFront,
                onBack: sendToBack,
                onDelete: deleteSelected,
                onPickFont: {
                    AppAnalytics.tap("editor_pick_font")
                    showFontPicker = true
                },
                onPlace: placeSelected,
                onExpand: item.kind == .existingText ? { scope in
                    expandPrintedSelection(scope)
                } : nil
            )
            .background(
                Color(.systemBackground)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
        } else if let item = selected, item.isMarkup || item.kind == .shape || item.kind == .redact || item.kind == .image || item.kind == .link {
            selectionActions(for: item)
                .background(
                    Color(.systemBackground)
                        .shadow(color: .black.opacity(0.08), radius: 8, y: -2)
                )
        } else if mode == .edit, editTool == .select, selected == nil, keyboardHeight < 1 {
            fieldHintBar
        }
    }

    private func updateKeyboardHeight(from notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let screen = UIScreen.main.bounds
        let overlap = max(0, screen.maxY - frame.minY)
        withAnimation(.easeOut(duration: duration)) {
            keyboardHeight = overlap
        }
    }

    private var zoomBottomInset: CGFloat {
        pages.count > 1 ? 28 : 8
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                AppAnalytics.tap("editor_cancel")
                if undoStack.isEmpty { dismiss() } else { showDiscardAlert = true }
            }
            .foregroundColor(DocumentEditorPalette.accent)
            .font(.body.weight(.medium))

            Picker("Mode", selection: $mode) {
                ForEach(DocumentEditorMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Button {
                AppAnalytics.tap("editor_undo")
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(undoStack.isEmpty)
            .foregroundColor(undoStack.isEmpty ? .secondary : DocumentEditorPalette.accent)

            if mode == .edit {
                Button {
                    AppAnalytics.tap("editor_redo")
                    redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(redoStack.isEmpty)
                .foregroundColor(redoStack.isEmpty ? .secondary : DocumentEditorPalette.accent)
            }

            Button("Save") {
                AppAnalytics.tap("editor_save", ["mode": mode.rawValue])
                save()
            }
            .font(.body.weight(.semibold))
            .foregroundColor(DocumentEditorPalette.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .onChange(of: mode) { _, newMode in
            AppAnalytics.tap("editor_mode", ["mode": newMode.rawValue])
            selectedID = nil
            if newMode == .edit {
                editTool = .select
            } else {
                markupTool = .highlight
            }
        }
    }

    private var editToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EditTool.allCases) { tool in
                    toolButton(
                        title: tool.title,
                        icon: tool.icon,
                        selected: editTool == tool
                    ) {
                        AppAnalytics.tap("editor_tool", ["tool": tool.rawValue])
                        selectEditTool(tool)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(.systemBackground))
    }

    private var markupToolbar: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MarkupTool.allCases) { tool in
                        toolButton(title: tool.title, icon: tool.icon, selected: markupTool == tool) {
                            AppAnalytics.tap("editor_markup", ["tool": tool.rawValue])
                            markupTool = tool
                            selectedID = nil
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                ForEach(DocumentEditorPalette.markupColors, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(markupColor == hex ? 0.7 : 0.15), lineWidth: markupColor == hex ? 2.5 : 1)
                        )
                        .onTapGesture { markupColor = hex }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .padding(.top, 4)
        .background(Color(.systemBackground))
    }

    private func toolButton(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundColor(selected ? DocumentEditorPalette.accent : .primary)
            .frame(width: 52, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? DocumentEditorPalette.accent.opacity(0.12) : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? DocumentEditorPalette.accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Canvas

    private var isPlacingSelection: Bool {
        guard let item = selected else { return false }
        return item.isText || item.kind == .image || item.kind == .shape || item.kind == .link || item.kind == .redact
    }

    private var canvasAllowsPan: Bool {
        if usesDrawingDrag { return false }
        if keyboardHeight > 40 { return true }
        if isPlacingSelection && zoomScale <= 1.05 { return false }
        return true
    }

    private var canvasAllowsPinch: Bool {
        if mode == .markup {
            switch markupTool {
            case .pen, .marker, .eraser: return false
            default: return true
            }
        }
        return true
    }

    private var usesDrawingDrag: Bool {
        if mode == .markup { return true }
        switch editTool {
        case .shape, .link, .redact:
            return selectedID == nil
        default:
            return false
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let fit = fittedPageSize(in: geo.size)
            ZStack {
                Color(.systemGray5)
                EditorZoomScrollView(
                    contentSize: fit,
                    panEnabled: canvasAllowsPan && !lensMode,
                    pinchEnabled: canvasAllowsPinch,
                    zoomScale: $zoomScale,
                    resetToken: zoomResetToken,
                    focusToken: zoomFocusToken,
                    focusRect: zoomFocusRect,
                    bottomInset: zoomBottomInset,
                    zoomRequest: zoomRequest,
                    zoomRequestToken: zoomRequestToken,
                    oneFingerSelectsText: mode == .edit && editTool == .select && !lensMode,
                    onTextDrag: (mode == .edit && editTool == .select && !lensMode) ? { start, current, ended in
                        handleTextDrag(from: start, to: current, ended: ended)
                    } : nil,
                    onTap: (usesDrawingDrag || lensMode) ? nil : { point in handleCanvasTap(at: point) }
                ) {
                    pageCanvas(size: fit)
                        .onAppear {
                            canvasSize = fit
                            revealSelectionIfNeeded(previousHeight: 0, height: fit.height)
                        }
                        .onChange(of: fit) { old, size in
                            canvasSize = size
                            revealSelectionIfNeeded(previousHeight: old.height, height: size.height)
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottom) {
                if pages.count > 1 {
                    pageBar
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private func pageCanvas(size: CGSize) -> some View {
        Image(uiImage: pageImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .overlay {
                if canvasSize != .zero {
                    canvasOverlays
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
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .documentMagnifier(image: pageImage, enabled: lensMode, immediate: true)
    }

    private func fittedPageSize(in bounds: CGSize) -> CGSize {
        let imageSize = pageImage.size
        let available = CGSize(width: max(bounds.width - 12, 1), height: max(bounds.height - 12, 1))
        guard imageSize.width > 1, imageSize.height > 1 else { return available }
        let ratio = min(available.width / imageSize.width, available.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            Button {
                AppAnalytics.tap("editor_zoom_out")
                requestZoom(zoomScale / 1.35)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 32, height: 32)
            }
            .disabled(zoomScale <= 1.02)

            Button {
                AppAnalytics.tap("editor_zoom_in")
                requestZoom(min(zoomScale * 1.4, 8))
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 32, height: 32)
            }
            .disabled(zoomScale >= 7.9)

            Button {
                AppAnalytics.tap("editor_lens", ["on": lensMode ? "false" : "true"])
                lensMode.toggle()
            } label: {
                Label("Lens", systemImage: lensMode ? "circle.circle.fill" : "circle.circle")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(lensMode ? Color.blue.opacity(0.16) : Color(.systemGray6), in: Capsule())
            }
            .accessibilityLabel(lensMode ? "Reading lens on" : "Reading lens")

            Spacer(minLength: 8)

            if zoomScale > 1.05 {
                Button {
                    AppAnalytics.tap("editor_zoom_reset")
                    zoomScale = 1
                    zoomResetToken += 1
                } label: {
                    Text(String(format: "%.1f×  ·  Reset", zoomScale))
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(DocumentEditorPalette.accent)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(.systemBackground))
    }

    private func revealSelectionIfNeeded(previousHeight: CGFloat, height: CGFloat) {
        guard abs(height - previousHeight) > 20, let item = selected, item.isText, item.kind != .existingText else { return }
        focusOnNormalizedRect(visibleEditRect(for: item))
    }

    private func visibleEditRect(for item: EditorElement) -> CGRect {
        guard let sourceID = item.sourceID,
              let source = elements.first(where: { $0.id == sourceID }) else {
            return item.rect
        }
        return source.rect.union(item.rect)
    }

    private func requestZoom(_ scale: CGFloat) {
        zoomRequest = min(max(scale, 1), 8)
        zoomRequestToken += 1
    }

    private func focusOnNormalizedRect(_ normalized: CGRect) {
        guard canvasSize.width > 8, canvasSize.height > 8 else { return }
        let pixel = normalized.pixelRect(in: canvasSize)
        let width = min(canvasSize.width, max(pixel.width + 52, canvasSize.width / 3.05))
        let height = min(canvasSize.height, max(pixel.height + 78, canvasSize.height / 3.4))
        var rect = CGRect(
            x: pixel.midX - width / 2,
            y: pixel.midY - height / 2,
            width: width,
            height: height
        )
        rect.origin.x = min(max(0, rect.origin.x), max(0, canvasSize.width - rect.width))
        rect.origin.y = min(max(0, rect.origin.y), max(0, canvasSize.height - rect.height))
        zoomFocusRect = rect
        zoomFocusToken += 1
    }

    private var canvasOverlays: some View {
        ZStack {
            ForEach(pageElements) { element in
                elementView(element)
            }
            if let draftRect {
                draftOverlay(draftRect)
            }
            if draftPoints.count > 1 {
                Path { path in
                    path.move(to: draftPoints[0])
                    for point in draftPoints.dropFirst() { path.addLine(to: point) }
                }
                .stroke(
                    Color(hex: markupColor).opacity(markupTool == .marker ? 0.4 : 1),
                    style: StrokeStyle(lineWidth: inkWidth(for: markupTool) * canvasSize.width, lineCap: .round, lineJoin: .round)
                )
            }
            if usesDrawingDrag, !lensMode {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(canvasGesture)
            }
            if mode == .edit, editTool == .select {
                formFieldHints
            }
            connectorArrows
            if mode == .edit, editTool == .select, !lensMode {
                textRangeOverlay
            }
            if let item = selected, isPlacingSelection, item.kind != .existingText {
                textBoxManipulator(item)
            }
        }
    }

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(value)
            }
            .onEnded { value in
                handleDragEnded(value)
            }
    }

    private var connectorArrows: some View {
        let byID = Dictionary(uniqueKeysWithValues: pageElements.map { ($0.id, $0) })
        return ZStack {
            ForEach(pageElements.filter { $0.kind == .addedText && $0.sourceID != nil }) { element in
                if let sourceID = element.sourceID, let source = byID[sourceID] {
                    let connector = EditorConnector.between(
                        source: source.rect.pixelRect(in: canvasSize),
                        target: element.rect.pixelRect(in: canvasSize)
                    )
                    let head = connector.headPoints(length: max(8, canvasSize.width * 0.018))
                    Path { path in
                        path.move(to: connector.start)
                        path.addQuadCurve(to: connector.end, control: connector.control)
                        path.move(to: connector.end)
                        path.addLine(to: head.0)
                        path.move(to: connector.end)
                        path.addLine(to: head.1)
                    }
                    .stroke(Color(hex: "#EA580C"), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func handleCanvasTap(at point: CGPoint) {
        if dismissCallout(at: point) { return }
        if mode == .markup {
            if let id = hitTest(at: point),
               let element = elements.first(where: { $0.id == id }),
               element.kind == .addedText {
                selectedID = id
                inspectorExpanded = false
                return
            }
            highlightTappedText(at: point)
            return
        }
        switch editTool {
        case .select:
            handleSelectTap(at: point)
        case .text:
            if let field = hitFormField(at: point) ?? nearestFormField(to: point) {
                activateFormField(field)
            } else {
                addText(at: point)
            }
        default:
            break
        }
    }

    private func elementView(_ element: EditorElement) -> some View {
        let rect = element.rect.pixelRect(in: canvasSize)
        let isSelected = element.id == selectedID
        return ZStack {
            switch element.kind {
            case .existingText:
                if element.isModified {
                    let padX = max(2, rect.height * 0.08)
                    let padY = max(1, rect.height * 0.08)
                    Color(hex: element.fillHex ?? "#FFFFFF")
                        .frame(width: rect.width + padX * 2, height: rect.height + padY * 2)
                    if !element.text.isEmpty {
                        replacementPreview(element, wordRect: rect)
                    }
                }
            case .addedText:
                if element.sourceID != nil {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: element.fillHex ?? "#FFFBEB"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(hex: "#D97706"), lineWidth: 1)
                        )
                        .overlay(alignment: .leading) {
                            if element.text.isEmpty {
                                Text("Type edited text")
                                    .font(.system(size: max(8, element.fontSize * canvasSize.height * 0.85)))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                            } else {
                                textBlock(element, in: rect)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if !isSelected {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color(hex: "#DC2626"))
                                    .font(.system(size: max(14, min(22, rect.height * 0.55)), weight: .bold))
                                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                                    .offset(x: 8, y: -8)
                            }
                        }
                } else {
                    textBlock(element, in: rect)
                }
            case .image:
                if let data = element.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: rect.width, height: rect.height)
                        .clipped()
                }
            case .shape:
                shapePreview(element, in: rect)
            case .link:
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.blue, lineWidth: 1.5)
                    .overlay(alignment: .topLeading) {
                        Text(element.text.isEmpty ? element.url : element.text)
                            .font(.system(size: max(9, rect.height * 0.38)))
                            .foregroundColor(.blue)
                            .underline()
                            .padding(4)
                            .lineLimit(2)
                    }
            case .redact:
                Rectangle().fill(Color.black)
            case .highlight:
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: element.colorHex).opacity(0.4))
            case .underline:
                GeometryReader { _ in
                    Path { path in
                        let y = rect.height * 0.9
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: rect.width, y: y))
                    }
                    .stroke(Color(hex: element.colorHex), style: StrokeStyle(lineWidth: max(2, rect.height * 0.12), lineCap: .round))
                }
            case .strike:
                GeometryReader { _ in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: rect.height * 0.5))
                        path.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.5))
                    }
                    .stroke(Color(hex: element.colorHex), style: StrokeStyle(lineWidth: max(2, rect.height * 0.12), lineCap: .round))
                }
            case .ink:
                inkPath(element)
            }
        }
        .frame(
            width: max(element.kind == .ink ? canvasSize.width : rect.width, 1),
            height: max(element.kind == .ink ? canvasSize.height : rect.height, 1)
        )
                .overlay {
            if isSelected, element.kind != .ink, element.kind != .existingText {
                selectionChrome(rect: CGRect(origin: .zero, size: rect.size))
            }
        }
        .rotationEffect(.degrees(element.kind == .ink ? 0 : element.rotation))
        .position(
            x: element.kind == .ink ? canvasSize.width / 2 : rect.midX,
            y: element.kind == .ink ? canvasSize.height / 2 : rect.midY
        )
        .allowsHitTesting(false)
    }

    private func textBlock(_ element: EditorElement, in rect: CGRect, exact: Bool = false) -> some View {
        let pointSize = max(8, element.fontSize * canvasSize.height)
        let text = Text(element.text)
            .font(.custom(element.fontName, size: pointSize))
            .bold(element.isBold)
            .italic(element.isItalic)
            .underline(element.isUnderline)
            .foregroundColor(Color(hex: element.colorHex))
            .multilineTextAlignment(element.alignment == 1 ? .center : element.alignment == 2 ? .trailing : .leading)
        if exact {
            return AnyView(text.lineLimit(1).fixedSize(horizontal: true, vertical: true))
        }
        return AnyView(
            text
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(
                    width: max(rect.width, 1),
                    height: max(rect.height, 1),
                    alignment: element.alignment == 1 ? .center : element.alignment == 2 ? .trailing : .leading
                )
        )
    }

    private func shapePreview(_ element: EditorElement, in rect: CGRect) -> some View {
        let color = Color(hex: element.colorHex)
        return Group {
            switch element.shapeKind {
            case .rectangle:
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color, lineWidth: max(1.5, element.lineWidth * canvasSize.width))
            case .ellipse:
                Ellipse()
                    .stroke(color, lineWidth: max(1.5, element.lineWidth * canvasSize.width))
            case .line:
                Path { path in
                    path.move(to: CGPoint(x: 0, y: rect.height))
                    path.addLine(to: CGPoint(x: rect.width, y: 0))
                }
                .stroke(color, style: StrokeStyle(lineWidth: max(1.5, element.lineWidth * canvasSize.width), lineCap: .round))
            case .arrow:
                Path { path in
                    path.move(to: CGPoint(x: 0, y: rect.height))
                    path.addLine(to: CGPoint(x: rect.width, y: 0))
                }
                .stroke(color, style: StrokeStyle(lineWidth: max(1.5, element.lineWidth * canvasSize.width), lineCap: .round))
            }
        }
        .frame(width: rect.width, height: rect.height)
    }

    private func inkPath(_ element: EditorElement) -> some View {
        Path { path in
            let pts = element.points.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
            guard let first = pts.first else { return }
            path.move(to: first)
            for p in pts.dropFirst() { path.addLine(to: p) }
        }
        .stroke(
            Color(hex: element.colorHex).opacity(element.inkOpacity),
            style: StrokeStyle(lineWidth: max(1.5, element.inkWidth * canvasSize.width), lineCap: .round, lineJoin: .round)
        )
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private func draftOverlay(_ rect: CGRect) -> some View {
        let kind: EditorElementKind = {
            if mode == .markup {
                switch markupTool {
                case .highlight: return .highlight
                case .underline: return .underline
                case .strike: return .strike
                default: return .highlight
                }
            }
            switch editTool {
            case .redact: return .redact
            case .link: return .link
            case .shape: return .shape
            default: return .highlight
            }
        }()
        return Group {
            switch kind {
            case .redact:
                Rectangle().fill(Color.black.opacity(0.85)).frame(width: rect.width, height: rect.height)
            case .highlight:
                Rectangle().fill(Color(hex: markupColor).opacity(0.35)).frame(width: rect.width, height: rect.height)
            case .underline, .strike:
                Rectangle().strokeBorder(Color(hex: markupColor), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
            default:
                Rectangle().strokeBorder(DocumentEditorPalette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: rect.width, height: rect.height)
            }
        }
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    private func selectionChrome(rect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .strokeBorder(Color(hex: "#3B82F6"), lineWidth: 1.5)
            ForEach(Array(handlePoints(in: rect).enumerated()), id: \.offset) { _, point in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .overlay(Rectangle().strokeBorder(Color(hex: "#3B82F6"), lineWidth: 1.2))
                    .position(point)
            }
        }
    }

    private func handlePoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: rect.width / 2, y: 0),
            CGPoint(x: rect.width, y: 0),
            CGPoint(x: rect.width, y: rect.height / 2),
            CGPoint(x: rect.width, y: rect.height),
            CGPoint(x: rect.width / 2, y: rect.height),
            CGPoint(x: 0, y: rect.height),
            CGPoint(x: 0, y: rect.height / 2)
        ]
    }

    private func textBoxManipulator(_ element: EditorElement) -> some View {
        let pixel = element.rect.pixelRect(in: canvasSize)
        let box = pixel.insetBy(dx: -16, dy: -16)
        return ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            moveSelected(translation: value.translation)
                        }
                        .onEnded { _ in
                            movingStart = nil
                        }
                )
            ForEach(Array(cornerHandles(in: CGRect(origin: .zero, size: box.size)).enumerated()), id: \.offset) { index, point in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color(hex: "#2563EB"), lineWidth: 1.6))
                    .frame(width: 18, height: 18)
                    .padding(6)
                    .position(point)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                resizeSelected(handle: index, translation: value.translation)
                            }
                            .onEnded { _ in
                                resizeStart = nil
                            }
                    )
            }
            if element.sourceID != nil {
                Button(action: dismissLinkedCallout) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(hex: "#DC2626"))
                        .font(.system(size: 22, weight: .bold))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .position(x: box.width - 8, y: 8)
            }
        }
        .frame(width: box.width, height: box.height)
        .position(x: pixel.midX, y: pixel.midY)
    }

    private func cornerHandles(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: 9, y: 9),
            CGPoint(x: rect.width - 9, y: 9),
            CGPoint(x: rect.width - 9, y: rect.height - 9),
            CGPoint(x: 9, y: rect.height - 9)
        ]
    }

    private func moveSelected(translation: CGSize) {
        guard let idx = selectedIndex else { return }
        if movingStart == nil {
            movingStart = elements[idx].rect
            pushUndo()
        }
        guard let start = movingStart else { return }
        let dx = translation.width / max(canvasSize.width, 1)
        let dy = translation.height / max(canvasSize.height, 1)
        var rect = start
        rect.origin.x = (start.minX + dx).clamped(to: 0...(1 - start.width))
        rect.origin.y = (start.minY + dy).clamped(to: 0...(1 - start.height))
        elements[idx].rect = rect
    }

    private func pinchSelected(_ scale: CGFloat) {
        guard let idx = selectedIndex else { return }
        if resizeStart == nil {
            resizeStart = elements[idx].rect
            resizeStartFont = elements[idx].fontSize
            pushUndo()
        }
        guard let start = resizeStart else { return }
        let s = min(max(scale, 0.45), 3.6)
        let width = max(0.04, start.width * s)
        let height = max(0.012, start.height * s)
        var rect = start
        rect.origin.x = start.midX - width / 2
        rect.origin.y = start.midY - height / 2
        rect.size.width = width
        rect.size.height = height
        applyResizedRect(rect, from: start, font: resizeStartFont, index: idx)
    }

    private func resizeSelected(handle: Int, translation: CGSize) {
        guard let idx = selectedIndex else { return }
        if resizeStart == nil {
            resizeStart = elements[idx].rect
            resizeStartFont = elements[idx].fontSize
            pushUndo()
        }
        guard let start = resizeStart else { return }
        let dx = translation.width / max(canvasSize.width, 1)
        let dy = translation.height / max(canvasSize.height, 1)
        var rect = start
        switch handle {
        case 0:
            rect.origin.x += dx
            rect.origin.y += dy
            rect.size.width -= dx
            rect.size.height -= dy
        case 1:
            rect.origin.y += dy
            rect.size.width += dx
            rect.size.height -= dy
        case 2:
            rect.size.width += dx
            rect.size.height += dy
        default:
            rect.origin.x += dx
            rect.size.width -= dx
            rect.size.height += dy
        }
        guard rect.width > 0.04, rect.height > 0.012 else { return }
        applyResizedRect(rect, from: start, font: resizeStartFont, index: idx)
    }

    private func applyResizedRect(_ rect: CGRect, from start: CGRect, font: CGFloat, index: Int) {
        elements[index].rect = rect.clampedNormalized()
        guard elements[index].isText, start.height > 0.0008 else { return }
        let scale = elements[index].rect.height / start.height
        elements[index].fontSize = min(max(font * scale, 0.007), 0.14)
    }

    private func placeSelected(_ placement: TextPlacement) {
        AppAnalytics.tap("editor_text_place", ["place": placement.rawValue])
        guard let idx = selectedIndex else { return }
        let item = elements[idx]
        let sourceElement: EditorElement? = {
            guard let sourceID = item.sourceID else { return nil }
            return elements.first(where: { $0.id == sourceID })
        }()
        let source: CGRect = {
            if let sourceElement { return sourceElement.rect }
            if let field = pageFormFields.first(where: { $0.rect.intersects(item.rect.insetBy(dx: -0.03, dy: -0.02)) }) {
                return field.rect
            }
            if let pending = pendingField, pending.pageIndex == currentPage {
                return pending.rect
            }
            return item.rect
        }()
        pushUndo()
        var rect = item.rect
        let width = rect.width
        let height = rect.height
        switch placement {
        case .onLine:
            rect.size.height = max(height, source.height * 0.92)
            rect.size.width = max(width, min(max(source.width * 0.55, 0.16), 0.42))
            rect.origin.x = source.minX
            rect.origin.y = source.midY - rect.height / 2
        case .above:
            rect.origin.x = source.minX
            rect.origin.y = max(0.008, source.minY - height - 0.01)
        case .below:
            rect.origin.x = source.minX
            rect.origin.y = min(0.98 - height, source.maxY + 0.01)
        case .left:
            rect.origin.x = max(0.01, source.minX - width - 0.012)
            rect.origin.y = source.midY - height / 2
        case .right:
            rect.origin.x = min(0.98 - width, source.maxX + 0.012)
            rect.origin.y = source.midY - height / 2
        }
        if placement == .onLine, let sourceElement = sourceElement {
            elements[idx].adoptTypography(from: sourceElement)
            elements[idx].rect = sourceElement.rect
            elements[idx].fillHex = nil
            elements[idx].sourceID = nil
            if let sourceIndex = elements.firstIndex(where: { $0.id == sourceElement.id }) {
                elements[sourceIndex].isModified = true
                elements[sourceIndex].text = ""
            }
            return
        }
        elements[idx].rect = rect.clampedNormalized()
    }

    // MARK: - Gestures

    private func handleDragChanged(_ value: DragGesture.Value) {
        guard canvasSize.width > 0 else { return }
        let translation = hypot(value.translation.width, value.translation.height)

        if mode == .markup {
            switch markupTool {
            case .pen, .marker:
                draftPoints.append(value.location)
            case .eraser:
                if translation > 2 { erase(at: value.location) }
            case .highlight, .underline, .strike:
                draftRect = rectFrom(value)
            }
            return
        }

        switch editTool {
        case .select:
            if translation < 4 { return }
            if movingStart == nil {
                if let id = hitTest(at: value.startLocation), let el = elements.first(where: { $0.id == id }) {
                    selectedID = id
                    movingStart = el.rect
                    pushUndo()
                } else {
                    selectedID = nil
                }
            }
            if let start = movingStart, let idx = selectedIndex {
                let dx = value.translation.width / canvasSize.width
                let dy = value.translation.height / canvasSize.height
                var rect = start
                rect.origin.x = (start.minX + dx).clamped(to: 0...(1 - start.width))
                rect.origin.y = (start.minY + dy).clamped(to: 0...(1 - start.height))
                elements[idx].rect = rect
            }
        case .text:
            if translation > 8 { draftRect = rectFrom(value) }
        case .image:
            break
        case .shape, .link, .redact:
            draftRect = rectFrom(value)
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        let translation = hypot(value.translation.width, value.translation.height)
        defer {
            draftRect = nil
            draftPoints = []
            movingStart = nil
        }

        if mode == .markup {
            switch markupTool {
            case .pen, .marker:
                commitInk(draftPoints + [value.location])
            case .eraser:
                break
            case .highlight, .underline, .strike:
                if translation < 8 {
                    highlightTappedText(at: value.startLocation)
                } else if let draft = draftRect {
                    commitTextMarkup(from: draft)
                }
            }
            return
        }

        switch editTool {
        case .select:
            if translation < 6 {
                handleSelectTap(at: value.startLocation)
            }
        case .text:
            if translation < 10 {
                if let field = hitFormField(at: value.startLocation) ?? nearestFormField(to: value.startLocation) {
                    activateFormField(field)
                } else {
                    addText(at: value.startLocation)
                }
            } else if let draft = draftRect, draft.width > 20 {
                addText(in: draft)
            }
        case .image:
            break
        case .shape:
            if let draft = draftRect, draft.width > 8, draft.height > 8 {
                commitShape(draft)
            }
        case .link:
            if let draft = draftRect, draft.width > 12, draft.height > 8 {
                pendingLinkRect = draft
                linkURL = "https://"
                showLinkAlert = true
            }
        case .redact:
            if let draft = draftRect, draft.width > 8, draft.height > 8 {
                commitRedact(draft)
            }
        }
    }

    private func rectFrom(_ value: DragGesture.Value) -> CGRect {
        let a = value.startLocation
        let b = value.location
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: max(abs(a.x - b.x), 4),
            height: max(abs(a.y - b.y), 4)
        )
    }

    private func hitTest(at point: CGPoint, skippingMarkup: Bool = false) -> UUID? {
        var wordHit: (id: UUID, area: CGFloat)?
        for element in pageElements.reversed() {
            if skippingMarkup && element.isMarkup { continue }
            if element.kind == .ink {
                if inkHits(element, at: point) { return element.id }
                continue
            }
            let rect = element.rect.pixelRect(in: canvasSize).insetBy(dx: -4, dy: -3)
            guard rect.contains(point) else { continue }
            if element.kind == .existingText {
                let area = rect.width * rect.height
                if wordHit == nil || area < wordHit!.area {
                    wordHit = (element.id, area)
                }
                continue
            }
            return element.id
        }
        return wordHit?.id
    }

    private var visibleFormFields: [DetectedFormField] {
        pageFormFields.filter { !isFieldFilled($0) }
    }

    private var pageFormFields: [DetectedFormField] {
        formFields.filter { $0.pageIndex == currentPage }
    }

    private func isFieldFilled(_ field: DetectedFormField) -> Bool {
        fillingElement(for: field) != nil
    }

    private func fillingElement(for field: DetectedFormField) -> EditorElement? {
        pageElements.first { element in
            guard element.kind == .addedText || element.kind == .image else { return false }
            let center = CGPoint(x: element.rect.midX, y: element.rect.midY)
            return field.rect.insetBy(dx: -0.006, dy: -0.004).contains(center)
        }
    }

    private var formFieldHints: some View {
        ForEach(visibleFormFields) { field in
            let rect = field.rect.pixelRect(in: canvasSize)
            RoundedRectangle(cornerRadius: field.kind == .checkbox ? 3 : 4)
                .strokeBorder(
                    fieldHintColor(field.kind),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )
                .background(
                    RoundedRectangle(cornerRadius: field.kind == .checkbox ? 3 : 4)
                        .fill(fieldHintColor(field.kind).opacity(0.06))
                )
                .overlay(alignment: .topLeading) {
                    Image(systemName: field.kind.icon)
                        .font(.system(size: max(8, min(11, rect.height * 0.45))))
                        .foregroundColor(fieldHintColor(field.kind).opacity(0.85))
                        .padding(3)
                }
                .frame(width: max(rect.width, 8), height: max(rect.height, 8))
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private func fieldHintColor(_ kind: FormFieldKind) -> Color {
        switch kind {
        case .text: return Color(hex: "#2563EB")
        case .date: return Color(hex: "#D97706")
        case .signature: return Color(hex: "#7C3AED")
        case .checkbox: return Color(hex: "#059669")
        }
    }

    private var fieldHintBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap")
                .foregroundColor(.secondary)
            Text("Drag across the words. Drag a blue dot to adjust. Pinch to zoom.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private func handleSelectTap(at point: CGPoint) {
        if Date() < ignoreSelectTapUntil { return }
        if dismissCallout(at: point) { return }
        if let word = printedWord(at: point) {
            selectPrintedRange(to: word)
            return
        }
        rangeAnchorID = nil
        rangeFocusID = nil
        rangeAwaitingEnd = false
        if let id = hitTest(at: point), let element = elements.first(where: { $0.id == id }) {
            let isPrintedLabel = element.kind == .existingText
                && DocumentEditorService.shared.isFieldLabel(element.text)
            if !isPrintedLabel {
                if element.kind == .existingText {
                    selectPrintedRange(to: element)
                    return
                }
                selectedID = id
                inspectorExpanded = false
                return
            }
            if let field = formField(matching: element) ?? hitFormField(at: point) {
                if let existing = fillingElement(for: field) {
                    selectedID = existing.id
                    inspectorExpanded = false
                    return
                }
                activateFormField(field)
                return
            }
            if let kind = DocumentEditorService.shared.classifyField(element.text) {
                activateFormField(synthesizedField(from: element, kind: kind))
                return
            }
        }
        if let field = hitFormField(at: point) ?? nearestFormField(to: point) {
            if let existing = fillingElement(for: field) {
                    selectedID = existing.id
                    inspectorExpanded = false
                    return
                }
            activateFormField(field)
            return
        }
        if let id = hitTest(at: point) {
            selectedID = id
            inspectorExpanded = false
            return
        }
        selectedID = nil
    }

    private func formField(matching element: EditorElement) -> DetectedFormField? {
        pageFormFields.first { field in
            field.labelRect.insetBy(dx: -0.012, dy: -0.01).intersects(element.rect)
        }
    }

    private func synthesizedField(from element: EditorElement, kind: FormFieldKind) -> DetectedFormField {
        let label = element.rect
        var fill = CGRect(
            x: label.maxX + 0.008,
            y: label.minY - 0.002,
            width: max(0.1, min(0.22, 0.97 - label.maxX)),
            height: max(0.02, label.height * 1.35)
        )
        if kind == .date, fill.width < 0.08 {
            fill = CGRect(
                x: min(max(label.minX, 0.04), 0.75),
                y: label.maxY + 0.004,
                width: 0.2,
                height: max(0.022, label.height * 1.4)
            )
        }
        if kind == .signature {
            fill.size.height = max(fill.height, 0.045)
            fill.size.width = max(fill.width, 0.28)
        }
        return DetectedFormField(
            id: UUID(),
            pageIndex: currentPage,
            kind: kind,
            label: element.text,
            rect: fill.clampedNormalized(),
            labelRect: label.clampedNormalized()
        )
    }

    private func hitFormField(at point: CGPoint) -> DetectedFormField? {
        let normalized = CGPoint(
            x: point.x / max(canvasSize.width, 1),
            y: point.y / max(canvasSize.height, 1)
        )
        return pageFormFields.first { field in
            field.rect.insetBy(dx: -0.014, dy: -0.012).contains(normalized)
                || field.labelRect.insetBy(dx: -0.02, dy: -0.014).contains(normalized)
        }
    }

    private func nearestFormField(to point: CGPoint) -> DetectedFormField? {
        let normalized = CGPoint(
            x: point.x / max(canvasSize.width, 1),
            y: point.y / max(canvasSize.height, 1)
        )
        guard let field = visibleFormFields.min(by: {
            distanceToField($0, point: normalized) < distanceToField($1, point: normalized)
        }) else { return nil }
        return distanceToField(field, point: normalized) < 0.07 ? field : nil
    }

    private func distanceToField(_ field: DetectedFormField, point: CGPoint) -> CGFloat {
        min(distanceToRect(field.rect, point), distanceToRect(field.labelRect, point))
    }

    private func distanceToRect(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func activateFormField(_ field: DetectedFormField) {
        pendingField = field
        focusOnNormalizedRect(field.rect)
        switch field.kind {
        case .text:
            insertText(in: field.rect, text: "", matching: field)
        case .date:
            pickedDate = Date()
            showDatePicker = true
        case .signature:
            showSignatureCapture = true
        case .checkbox:
            toggleCheckbox(field)
        }
    }

    private func insertText(in rect: CGRect, text: String, matching field: DetectedFormField? = nil) {
        pushUndo()
        var element = EditorElement.addedText(
            page: currentPage,
            rect: rect.clampedNormalized(),
            zIndex: nextZ,
            text: text,
            fontSize: max(0.016, rect.height * 0.72)
        )
        if let source = typography(matching: field, near: rect) {
            element.adoptTypography(from: source)
        }
        nextZ += 1
        elements.append(element)
        selectedID = element.id
        inspectorExpanded = false
        editTool = .select
    }

    private func typography(matching field: DetectedFormField?, near rect: CGRect) -> EditorElement? {
        if let field {
            let labeled = pageElements.filter {
                $0.kind == .existingText && !$0.text.isEmpty && $0.rect.intersects(field.labelRect.insetBy(dx: -0.012, dy: -0.01))
            }
            if let match = labeled.max(by: { $0.rect.width < $1.rect.width }) {
                return match
            }
        }
        return pageElements
            .filter { $0.kind == .existingText && !$0.text.isEmpty }
            .min { lhs, rhs in
                let left = abs(lhs.rect.midY - rect.midY) * 4 + abs(lhs.rect.midX - rect.midX)
                let right = abs(rhs.rect.midY - rect.midY) * 4 + abs(rhs.rect.midX - rect.midX)
                return left < right
            }
    }

    private func insertDate() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let text = formatter.string(from: pickedDate)
        if let field = pendingField {
            insertText(in: field.rect, text: text, matching: field)
        }
        showDatePicker = false
        pendingField = nil
    }

    private func insertSignature(_ image: UIImage) {
        guard let field = pendingField else { return }
        guard let data = image.jpegData(compressionQuality: 0.86) else { return }
        pushUndo()
        let aspect = image.size.height / max(image.size.width, 1)
        var rect = field.rect
        rect.size.height = max(rect.height, min(0.08, rect.width * aspect))
        let element = EditorElement(
            id: UUID(),
            pageIndex: currentPage,
            kind: .image,
            rect: rect.clampedNormalized(),
            zIndex: nextZ,
            imageData: data
        )
        nextZ += 1
        elements.append(element)
        selectedID = element.id
        editTool = .select
        pendingField = nil
    }

    private func toggleCheckbox(_ field: DetectedFormField) {
        if let existing = pageElements.first(where: { $0.kind == .addedText && $0.rect.intersects(field.rect) }) {
            selectedID = existing.id
            deleteSelected()
            pendingField = nil
            return
        }
        insertText(in: field.rect, text: "✓", matching: field)
        pendingField = nil
    }

    private var datePickerSheet: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    pendingField?.label ?? "Date",
                    selection: $pickedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
                Spacer()
            }
            .navigationTitle(pendingField?.label.isEmpty == false ? pendingField!.label : "Insert Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        AppAnalytics.tap("editor_date_cancel")
                        showDatePicker = false
                        pendingField = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        AppAnalytics.tap("editor_date_insert")
                        insertDate()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func inkHits(_ element: EditorElement, at point: CGPoint) -> Bool {
        let pts = element.points.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
        let threshold = max(12, element.inkWidth * canvasSize.width * 1.8)
        for pair in zip(pts, pts.dropFirst()) {
            if distance(point, to: pair.0, pair.1) < threshold { return true }
        }
        return false
    }

    private func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0.001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    // MARK: - Mutations

    private func selectEditTool(_ tool: EditTool) {
        editTool = tool
        selectedID = nil
        switch tool {
        case .image:
            showImagePicker = true
        case .shape:
            showShapePicker = true
        default:
            break
        }
    }

    private func addText(at point: CGPoint) {
        addText(in: CGRect(x: point.x - 80, y: point.y - 16, width: 160, height: 36))
    }

    private func addText(in canvasRect: CGRect) {
        pushUndo()
        var element = EditorElement.addedText(
            page: currentPage,
            rect: CGRect.normalized(from: canvasRect, in: canvasSize),
            zIndex: nextZ
        )
        nextZ += 1
        element.colorHex = "#111111"
        elements.append(element)
        selectedID = element.id
        editTool = .select
    }

    private func commitShape(_ canvasRect: CGRect) {
        pushUndo()
        var element = EditorElement(
            id: UUID(),
            pageIndex: currentPage,
            kind: .shape,
            rect: CGRect.normalized(from: canvasRect, in: canvasSize),
            zIndex: nextZ,
            colorHex: "#2563EB",
            shapeKind: shapeKind
        )
        nextZ += 1
        elements.append(element)
        selectedID = element.id
        editTool = .select
    }

    private func commitRedact(_ canvasRect: CGRect) {
        pushUndo()
        let element = EditorElement(
            id: UUID(),
            pageIndex: currentPage,
            kind: .redact,
            rect: CGRect.normalized(from: canvasRect, in: canvasSize),
            zIndex: nextZ
        )
        nextZ += 1
        elements.append(element)
        selectedID = element.id
    }

    private func commitLink() {
        guard let canvasRect = pendingLinkRect else { return }
        pushUndo()
        var element = EditorElement(
            id: UUID(),
            pageIndex: currentPage,
            kind: .link,
            rect: CGRect.normalized(from: canvasRect, in: canvasSize),
            zIndex: nextZ,
            text: linkURL,
            url: linkURL
        )
        nextZ += 1
        elements.append(element)
        selectedID = element.id
        pendingLinkRect = nil
        editTool = .select
    }

    private func commitTextMarkup(from canvasRect: CGRect) {
        let normalized = CGRect.normalized(from: canvasRect, in: canvasSize)
        let kind: EditorElementKind = {
            switch markupTool {
            case .underline: return .underline
            case .strike: return .strike
            default: return .highlight
            }
        }()
        let hits = pageElements.filter { $0.kind == .existingText && $0.rect.intersects(normalized.insetBy(dx: -0.01, dy: -0.01)) }
        pushUndo()
        if hits.isEmpty {
            appendMarkup(kind: kind, rect: normalized)
        } else {
            for hit in hits {
                appendMarkup(kind: kind, rect: hit.rect.insetBy(dx: -0.004, dy: -0.01))
            }
            beginLinkedEdit(from: hits[0], alreadyPushedUndo: true)
        }
    }

    private func highlightTappedText(at point: CGPoint) {
        guard let id = hitTest(at: point, skippingMarkup: true),
              let element = elements.first(where: { $0.id == id }) else { return }
        if element.kind == .addedText {
            selectedID = element.id
            inspectorExpanded = false
            return
        }
        guard element.kind == .existingText else { return }
        let kind: EditorElementKind = {
            switch markupTool {
            case .underline: return .underline
            case .strike: return .strike
            default: return .highlight
            }
        }()
        pushUndo()
        appendMarkup(kind: kind, rect: element.rect.insetBy(dx: -0.004, dy: -0.01))
        beginLinkedEdit(from: element, alreadyPushedUndo: true)
    }

    private func appendMarkup(kind: EditorElementKind, rect: CGRect) {
        let element = EditorElement.markup(
            kind: kind,
            page: currentPage,
            rect: rect.clampedNormalized(),
            color: markupColor,
            zIndex: nextZ
        )
        nextZ += 1
        elements.append(element)
    }

    private var orderedPrintedWords: [EditorElement] {
        let pitch = linePitch()
        return elements.filter { $0.pageIndex == currentPage && $0.kind == .existingText }.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > pitch * 0.65 {
                return lhs.rect.minY < rhs.rect.minY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    /// Typical printed line height. Tall recognition boxes are ignored so a paragraph stays separate lines.
    private func linePitch() -> CGFloat {
        let heights = elements
            .filter { $0.pageIndex == currentPage && $0.kind == .existingText }
            .map(\.rect.height)
            .filter { $0 > 0.004 }
            .sorted()
        guard !heights.isEmpty else { return 0.015 }
        return max(heights[min(heights.count - 1, heights.count * 3 / 10)], 0.008)
    }

    private var selectedWordRange: [EditorElement] {
        let words = orderedPrintedWords
        guard let anchor = rangeAnchorID, let focus = rangeFocusID,
              let start = words.firstIndex(where: { $0.id == anchor }),
              let end = words.firstIndex(where: { $0.id == focus }) else { return [] }
        return Array(words[min(start, end)...max(start, end)])
    }

    private func handleTextDrag(from start: CGPoint, to current: CGPoint, ended: Bool) {
        let moved = hypot(current.x - start.x, current.y - start.y)
        guard moved > 8 else { return }
        ignoreSelectTapUntil = Date().addingTimeInterval(0.35)
        if let edge = selectionHandle(at: start) {
            guard let word = wordForSelection(at: current, fromHandle: true) else { return }
            moveSelectionEdge(edge, to: word)
        } else if let startWord = wordForSelection(at: start, fromHandle: false) {
            rangeAnchorID = startWord.id
            if let word = wordForSelection(at: current, fromHandle: false) {
                rangeFocusID = word.id
            }
        } else if let word = wordForSelection(at: current, fromHandle: false) {
            if rangeAnchorID == nil { rangeAnchorID = word.id }
            rangeFocusID = word.id
        }
        guard rangeAnchorID != nil, rangeFocusID != nil else { return }
        rangeAwaitingEnd = false
        syncPrintedRange()
        _ = ended
    }

    /// Moves only the grabbed end. The other end stays, so extending the selection keeps every word already inside it.
    private func moveSelectionEdge(_ edge: SelectionEdge, to word: EditorElement) {
        let words = orderedPrintedWords
        guard let anchor = rangeAnchorID, let focus = rangeFocusID,
              let anchorIndex = words.firstIndex(where: { $0.id == anchor }),
              let focusIndex = words.firstIndex(where: { $0.id == focus }),
              let wordIndex = words.firstIndex(where: { $0.id == word.id }) else {
            rangeFocusID = word.id
            return
        }
        let earlier = min(anchorIndex, focusIndex)
        let later = max(anchorIndex, focusIndex)
        if edge == .start {
            let nextEarlier = min(wordIndex, later)
            rangeAnchorID = words[nextEarlier].id
            rangeFocusID = words[later].id
        } else {
            let nextLater = max(wordIndex, earlier)
            rangeAnchorID = words[earlier].id
            rangeFocusID = words[nextLater].id
        }
    }

    private var textRangeOverlay: some View {
        let lines = selectionBands(for: selectedWordRange)
        let unit = 1 / max(zoomScale, 1)
        return ZStack {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: max(1, 2 * unit))
                    .fill(Color(hex: "#3B82F6").opacity(0.22))
                    .frame(width: rect.width + 2 * unit, height: rect.height + 2 * unit)
                    .position(x: rect.midX, y: rect.midY)
            }
            if let first = lines.first {
                selectionCaret(at: CGPoint(x: first.minX, y: first.maxY), unit: unit)
            }
            if let last = lines.last {
                selectionCaret(at: CGPoint(x: last.maxX, y: last.maxY), unit: unit)
            }
        }
        .allowsHitTesting(false)
    }

    private func selectionBands(for words: [EditorElement]) -> [CGRect] {
        var lines: [CGRect] = []
        for word in words {
            let rect = word.rect.pixelRect(in: canvasSize)
            if let index = lines.indices.last,
               abs(lines[index].midY - rect.midY) < linePitch() * canvasSize.height * 0.65 {
                lines[index] = lines[index].union(rect)
            } else {
                lines.append(rect)
            }
        }
        return lines
    }

    private func selectionCaret(at point: CGPoint, unit: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(hex: "#2563EB"))
                .frame(width: max(1.25, 2 * unit), height: 14 * unit)
            Circle()
                .fill(Color(hex: "#2563EB"))
                .frame(width: 11 * unit, height: 11 * unit)
                .overlay(Circle().stroke(Color.white, lineWidth: max(0.8, 1.5 * unit)))
        }
        .position(x: point.x, y: point.y + 8 * unit)
    }

    private enum SelectionEdge { case start, end }

    private func selectionHandle(at point: CGPoint) -> SelectionEdge? {
        let lines = selectionBands(for: selectedWordRange)
        guard let first = lines.first, let last = lines.last else { return nil }
        let slop = 44 / max(zoomScale, 1)
        let start = caretGrabPoint(CGPoint(x: first.minX, y: first.maxY))
        let end = caretGrabPoint(CGPoint(x: last.maxX, y: last.maxY))
        let startDistance = hypot(point.x - start.x, point.y - start.y)
        let endDistance = hypot(point.x - end.x, point.y - end.y)
        if startDistance <= slop, startDistance <= endDistance { return .start }
        if endDistance <= slop { return .end }
        return nil
    }

    private func caretGrabPoint(_ anchor: CGPoint) -> CGPoint {
        CGPoint(x: anchor.x, y: anchor.y + 15 / max(zoomScale, 1))
    }

    private func printedWord(at point: CGPoint) -> EditorElement? {
        wordForSelection(at: point, fromHandle: false)
    }

    /// Picks the word on the line nearest the finger. A handle sits under the line, so that drag is lifted back onto its own line until the finger actually crosses into the next one.
    private func wordForSelection(at point: CGPoint, fromHandle: Bool) -> EditorElement? {
        let lines = printedLines()
        guard !lines.isEmpty else { return nil }
        let sampleY = fromHandle ? point.y - 15 / max(zoomScale, 1) : point.y
        let sample = CGPoint(x: point.x, y: sampleY)
        let rects = lines.map { linePixelRect($0) }
        var chosen = 0
        var matched = false
        for index in rects.indices {
            let above: CGFloat = index == 0
                ? -.greatestFiniteMagnitude
                : (rects[index - 1].maxY + rects[index].minY) / 2
            let below: CGFloat = index + 1 == rects.count
                ? .greatestFiniteMagnitude
                : (rects[index].maxY + rects[index + 1].minY) / 2
            if sample.y >= above, sample.y < below {
                chosen = index
                matched = true
                break
            }
        }
        if !matched {
            chosen = rects.enumerated().min {
                abs($0.element.midY - sample.y) < abs($1.element.midY - sample.y)
            }?.offset ?? 0
        }
        return wordOnLine(lines[chosen], atX: sample.x)
    }

    private func printedLines() -> [[EditorElement]] {
        var lines: [[EditorElement]] = []
        for word in orderedPrintedWords {
            if let index = lines.indices.last {
                let anchor = lines[index][0]
                if abs(anchor.rect.midY - word.rect.midY) < linePitch() * 0.65 {
                    lines[index].append(word)
                    continue
                }
            }
            lines.append([word])
        }
        return lines
    }

    private func linePixelRect(_ line: [EditorElement]) -> CGRect {
        guard let first = line.first else { return .zero }
        return line.dropFirst().reduce(first.rect.pixelRect(in: canvasSize)) {
            $0.union($1.rect.pixelRect(in: canvasSize))
        }
    }

    private func wordOnLine(_ line: [EditorElement], atX x: CGFloat) -> EditorElement? {
        let sorted = line.sorted { $0.rect.minX < $1.rect.minX }
        guard !sorted.isEmpty else { return nil }
        for (index, word) in sorted.enumerated() {
            if index == sorted.count - 1 { return word }
            let rect = word.rect.pixelRect(in: canvasSize)
            let next = sorted[index + 1].rect.pixelRect(in: canvasSize)
            if x < (rect.maxX + next.minX) / 2 { return word }
        }
        return sorted.last
    }

    private func selectPrintedRange(to word: EditorElement) {
        if let last = lastPrintedTap, last.id == word.id, Date().timeIntervalSince(last.time) < 0.35 {
            return
        }
        lastPrintedTap = (word.id, Date())
        if rangeAwaitingEnd, let anchor = rangeAnchorID, anchor != word.id {
            rangeFocusID = word.id
            rangeAwaitingEnd = false
        } else {
            rangeAnchorID = word.id
            rangeFocusID = word.id
            rangeAwaitingEnd = true
        }
        syncPrintedRange()
    }

    private func syncPrintedRange() {
        let words = selectedWordRange
        guard let first = words.first, let idx = elements.firstIndex(where: { $0.id == first.id }) else { return }
        let ids = Set(words.map(\.id))
        for index in elements.indices where elements[index].pageIndex == currentPage && elements[index].kind == .existingText {
            if !ids.contains(elements[index].id), elements[index].isModified, elements[index].text.isEmpty {
                elements[index].text = elements[index].originalText
                elements[index].isModified = false
            }
        }
        if !elements[idx].isModified {
            elements[idx].text = selectionFieldText(from: words)
        } else {
            coverPrintedRange(keepingTextOn: first.id)
        }
        selectedID = first.id
        inspectorExpanded = false
    }

    private func coverPrintedRange(keepingTextOn keeper: UUID) {
        for word in selectedWordRange {
            guard let index = elements.firstIndex(where: { $0.id == word.id }) else { continue }
            if elements[index].fillHex == nil {
                elements[index].fillHex = DocumentEditorService.shared.paperHex(in: pageImage, around: elements[index].rect)
            }
            elements[index].isModified = true
            if word.id != keeper {
                elements[index].text = ""
            } else {
                applySelectionStyle(to: index)
                matchFontSizeToLine(index: index)
                elements[index].zIndex = nextZ
                nextZ += 1
            }
        }
    }

    private func expandPrintedSelection(_ scope: PrintedSelectionScope) {
        let words = orderedPrintedWords
        guard !words.isEmpty else { return }
        let range = selectedWordRange
        let seed = range.first ?? words.first(where: { $0.id == selectedID })
        guard let seed, let seedIndex = words.firstIndex(where: { $0.id == seed.id }) else { return }
        var lower = range.first.flatMap { item in words.firstIndex(where: { $0.id == item.id }) } ?? seedIndex
        var upper = range.last.flatMap { item in words.firstIndex(where: { $0.id == item.id }) } ?? seedIndex
        let pitch = linePitch()
        func breaks(_ before: EditorElement, _ after: EditorElement) -> Bool {
            let gap = after.rect.minY - before.rect.maxY
            if scope == .paragraph {
                return gap > pitch * 0.85 || abs(after.rect.midY - before.rect.midY) > pitch * 1.45
            }
            if gap > pitch * 0.85 { return true }
            let ending = before.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            return ending.hasSuffix(".") || ending.hasSuffix("!") || ending.hasSuffix("?")
        }
        while lower > 0, !breaks(words[lower - 1], words[lower]) {
            lower -= 1
        }
        while upper + 1 < words.count, !breaks(words[upper], words[upper + 1]) {
            upper += 1
        }
        rangeAnchorID = words[lower].id
        rangeFocusID = words[upper].id
        rangeAwaitingEnd = false
        syncPrintedRange()
    }

    private func applySelectionStyle(to index: Int) {
        let source = selectedWordRange.max { $0.originalText.count < $1.originalText.count } ?? elements[index]
        elements[index].fontName = source.fontName
        elements[index].isBold = source.isBold
        elements[index].isItalic = source.isItalic
        elements[index].isUnderline = source.isUnderline
        elements[index].colorHex = source.colorHex
    }

    private func replacementPreview(_ element: EditorElement, wordRect: CGRect) -> some View {
        let group = replacementGroup(containing: element)
        let union = group.reduce(element.rect) { $0.union($1.rect) }.pixelRect(in: canvasSize)
        let pointSize = max(6, element.fontSize * canvasSize.height)
        return Text(element.text)
            .font(.custom(element.fontName, size: pointSize))
            .bold(element.isBold)
            .italic(element.isItalic)
            .underline(element.isUnderline)
            .foregroundColor(Color(hex: element.colorHex))
            .lineLimit(group.count > 1 ? 12 : 1)
            .frame(width: max(union.width, 1), height: max(union.height, pointSize), alignment: .topLeading)
            .offset(x: union.midX - wordRect.midX, y: union.midY - wordRect.midY)
    }

    private func replacementGroup(containing element: EditorElement) -> [EditorElement] {
        let pitch = linePitch()
        let words = elements.filter {
            $0.pageIndex == element.pageIndex && $0.kind == .existingText && $0.isModified
        }.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > pitch * 0.65 {
                return lhs.rect.minY < rhs.rect.minY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
        var groups: [[EditorElement]] = []
        for word in words {
            if word.text.isEmpty, let last = groups.last?.last, word.rect.minY - last.rect.maxY < pitch * 1.25 {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups.first { $0.contains { $0.id == element.id } } ?? [element]
    }

    private func beginInPlaceEdit(from source: EditorElement) {
        guard let idx = elements.firstIndex(where: { $0.id == source.id }) else { return }
        if !elements[idx].isModified {
            pushUndo()
            elements[idx].isModified = true
            if elements[idx].fillHex == nil {
                elements[idx].fillHex = DocumentEditorService.shared.paperHex(in: pageImage, around: elements[idx].rect)
            }
            matchFontSizeToLine(index: idx)
        }
        elements[idx].zIndex = nextZ
        nextZ += 1
        selectedID = source.id
        inspectorExpanded = false
    }

    private func selectionFieldText(from words: [EditorElement]) -> String {
        var result = ""
        var previous: EditorElement?
        for word in words {
            let piece = word.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let previous {
                let sameLine = abs(word.rect.midY - previous.rect.midY) < max(word.rect.height, previous.rect.height) * 0.7
                let gap = word.rect.minX - previous.rect.maxX
                let height = max(word.rect.height, previous.rect.height)
                let sameWord = sameLine && gap < height * 0.22
                let punctuation = piece.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
                if sameWord || punctuation {
                    result += piece
                } else {
                    if !result.hasSuffix(" ") { result += " " }
                    result += piece
                }
            } else {
                result = piece
            }
            previous = word
        }
        return result
    }

    private func matchFontSizeToLine(index: Int) {
        guard canvasSize.height > 1 else { return }
        let element = elements[index]
        let pitch = linePitch()
        let own = max(element.rect.height, 0.006)
        let line = own > pitch * 1.6 ? pitch : own
        let pixelHeight = line * canvasSize.height
        let probe = editorUIFont(name: element.fontName, size: 100, bold: element.isBold, italic: element.isItalic)
        let cap = max(probe.capHeight, 1)
        let point = 100 * (pixelHeight * 0.68) / cap
        elements[index].fontSize = min(max(point / canvasSize.height, 0.006), 0.06)
    }

    private func growWidthToFit(index: Int) {
        guard canvasSize.width > 1 else { return }
        let element = elements[index]
        guard element.isText, !element.text.isEmpty else { return }
        let multiLine = replacementGroup(containing: element).count > 1
            && selectionBands(for: replacementGroup(containing: element)).count > 1
        if multiLine { return }
        let point = max(6, element.fontSize * canvasSize.height)
        let font = editorUIFont(name: element.fontName, size: point, bold: element.isBold, italic: element.isItalic)
        let measured = (element.text as NSString).size(withAttributes: [.font: font]).width + 4
        let needed = measured / canvasSize.width
        let limit = max(element.rect.width, 0.98 - element.rect.minX)
        if needed > element.rect.width {
            elements[index].rect.size.width = min(needed, limit)
        }
    }

    private func beginLinkedEdit(from source: EditorElement, alreadyPushedUndo: Bool = false) {
        if let existing = elements.first(where: {
            $0.sourceID == source.id && $0.kind == .addedText && $0.pageIndex == currentPage
        }) {
            selectedID = existing.id
            inspectorExpanded = false
            focusOnNormalizedRect(source.rect.union(existing.rect).insetBy(dx: -0.02, dy: -0.02))
            return
        }
        if !alreadyPushedUndo { pushUndo() }
        let rect = calloutRect(for: source.rect)
        var element = EditorElement.addedText(
            page: currentPage,
            rect: rect,
            zIndex: nextZ,
            text: source.text,
            fontSize: max(0.016, source.fontSize),
            sourceID: source.id
        )
        element.adoptTypography(from: source)
        element.originalText = source.text
        element.fillHex = "#FFFBEB"
        element.colorHex = readableCalloutColor(element.colorHex)
        nextZ += 1
        elements.append(element)
        selectedID = element.id
        inspectorExpanded = false
        focusOnNormalizedRect(source.rect.union(rect).insetBy(dx: -0.02, dy: -0.02))
    }

    private func readableCalloutColor(_ hex: String) -> String {
        let color = UIColor(editorHex: hex)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return (red + green + blue) / 3 > 0.72 ? "#111111" : hex
    }

    private func calloutRect(for source: CGRect) -> CGRect {
        let width = min(0.46, max(0.24, source.width * 1.2))
        let height = max(0.034, source.height * 1.6)
        var x = min(0.96 - width, source.maxX + 0.035)
        var y = source.minY - height - 0.03
        if y < 0.02 {
            y = min(0.95 - height, source.maxY + 0.025)
        }
        if x < 0.02 { x = 0.02 }
        return CGRect(x: x, y: y, width: width, height: height).clampedNormalized()
    }

    private func commitInk(_ points: [CGPoint]) {
        guard points.count > 1, canvasSize.width > 0 else { return }
        pushUndo()
        let normalized = points.map { CGPoint(x: $0.x / canvasSize.width, y: $0.y / canvasSize.height) }
        var element = EditorElement(
            id: UUID(),
            pageIndex: currentPage,
            kind: .ink,
            rect: .zero,
            zIndex: nextZ,
            colorHex: markupColor,
            points: normalized,
            inkWidth: inkWidth(for: markupTool),
            inkOpacity: markupTool == .marker ? 0.4 : 1
        )
        nextZ += 1
        elements.append(element)
        selectedID = element.id
    }

    private func inkWidth(for tool: MarkupTool) -> CGFloat {
        switch tool {
        case .marker: return 0.028
        case .pen: return 0.009
        default: return 0.012
        }
    }

    private func erase(at point: CGPoint) {
        let hitIDs = pageElements.filter { element in
            guard element.isMarkup else { return false }
            if element.kind == .ink { return inkHits(element, at: point) }
            return element.rect.pixelRect(in: canvasSize).insetBy(dx: -8, dy: -8).contains(point)
        }.map(\.id)
        guard !hitIDs.isEmpty else { return }
        if undoStack.last != elements { pushUndo() }
        elements.removeAll { hitIDs.contains($0.id) }
        if let selectedID, hitIDs.contains(selectedID) { self.selectedID = nil }
    }

    private func addPickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        AppAnalytics.tap("editor_add_image")
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.86) else { return }
        await MainActor.run {
            pushUndo()
            let aspect = image.size.height / max(image.size.width, 1)
            let width: CGFloat = 0.36
            let height = width * aspect
            var element = EditorElement(
                id: UUID(),
                pageIndex: currentPage,
                kind: .image,
                rect: CGRect(x: 0.5 - width / 2, y: 0.32, width: width, height: min(height, 0.45)).clampedNormalized(),
                zIndex: nextZ,
                imageData: jpeg
            )
            nextZ += 1
            elements.append(element)
            selectedID = element.id
            editTool = .select
            photoItem = nil
        }
    }

    private func updateSelected(_ transform: (inout EditorElement) -> Void) {
        guard let idx = selectedIndex else { return }
        if elements[idx].kind == .existingText, !elements[idx].isModified {
            pushUndo()
            elements[idx].isModified = true
        }
        transform(&elements[idx])
        if elements[idx].kind == .existingText, elements[idx].isModified {
            coverPrintedRange(keepingTextOn: elements[idx].id)
            growWidthToFit(index: idx)
        } else if elements[idx].isText, elements[idx].isModified {
            growWidthToFit(index: idx)
        }
    }

    private func copySelected() {
        guard var item = selected else { return }
        AppAnalytics.tap("editor_copy")
        pushUndo()
        item = EditorElement(
            id: UUID(),
            pageIndex: item.pageIndex,
            kind: item.kind == .existingText ? .addedText : item.kind,
            rect: CGRect(x: item.rect.minX + 0.03, y: item.rect.minY + 0.03, width: item.rect.width, height: item.rect.height).clampedNormalized(),
            rotation: item.rotation,
            zIndex: nextZ,
            text: item.text,
            originalText: item.originalText,
            fontName: item.fontName,
            fontSize: item.fontSize,
            isBold: item.isBold,
            isItalic: item.isItalic,
            isUnderline: item.isUnderline,
            alignment: item.alignment,
            colorHex: item.colorHex,
            isModified: true,
            imageData: item.imageData,
            shapeKind: item.shapeKind,
            fillHex: item.fillHex,
            lineWidth: item.lineWidth,
            url: item.url,
            sourceID: item.sourceID,
            points: item.points,
            inkWidth: item.inkWidth,
            inkOpacity: item.inkOpacity
        )
        nextZ += 1
        elements.append(item)
        selectedID = item.id
    }

    private func bringToFront() {
        guard let idx = selectedIndex else { return }
        AppAnalytics.tap("editor_front")
        pushUndo()
        elements[idx].zIndex = nextZ
        nextZ += 1
    }

    private func sendToBack() {
        guard let idx = selectedIndex else { return }
        AppAnalytics.tap("editor_back")
        pushUndo()
        let minZ = (elements.map(\.zIndex).min() ?? 0) - 1
        elements[idx].zIndex = minZ
    }

    private func dismissLinkedCallout() {
        dismissLinkedCallout(id: selectedID)
    }

    private func dismissCallout(at point: CGPoint) -> Bool {
        guard let callout = pageElements.first(where: { element in
            element.kind == .addedText && element.sourceID != nil && closeHitRect(for: element).contains(point)
        }) else { return false }
        dismissLinkedCallout(id: callout.id)
        return true
    }

    private func closeHitRect(for element: EditorElement) -> CGRect {
        let pixel = element.rect.pixelRect(in: canvasSize)
        return CGRect(x: pixel.maxX - 6, y: pixel.minY - 22, width: 32, height: 32)
    }

    private func dismissLinkedCallout(id: UUID?) {
        guard let id,
              let idx = elements.firstIndex(where: { $0.id == id && $0.kind == .addedText && $0.sourceID != nil })
        else { return }
        AppAnalytics.tap("editor_close_callout")
        pushUndo()
        elements.remove(at: idx)
        if selectedID == id { selectedID = nil }
    }

    private func deleteSelected() {
        guard let id = selectedID, let idx = selectedIndex else { return }
        AppAnalytics.tap("editor_delete")
        pushUndo()
        if elements[idx].kind == .existingText, !elements[idx].isModified {
            elements[idx].isModified = true
            elements[idx].text = ""
        } else {
            elements.remove(at: idx)
        }
        selectedID = nil
        _ = id
    }

    private func pushUndo() {
        undoStack.append(elements)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(elements)
        elements = previous
        selectedID = nil
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(elements)
        elements = next
        selectedID = nil
    }

    private func save() {
        isSaving = true
        let snapshot = elements
        let source = pages
        Task.detached(priority: .userInitiated) {
            let rendered = DocumentEditorService.shared.render(pages: source, elements: snapshot)
            await MainActor.run {
                isSaving = false
                onComplete(rendered)
                dismiss()
            }
        }
    }

    private func recognizeCurrentPage() async {
        guard !ocrPages.contains(currentPage), currentPage < pages.count else { return }
        isRecognizing = ocrPages.isEmpty
        let image = pages[currentPage]
        let blocks = await DocumentEditorService.shared.detectTextBlocks(in: image)
        ocrPages.insert(currentPage)
        var z = nextZ
        for block in blocks {
            for piece in block.editablePieces {
                let exists = elements.contains {
                    $0.pageIndex == currentPage
                        && $0.kind == .existingText
                        && $0.rect.intersects(piece.rect.insetBy(dx: 0.002, dy: 0.002))
                        && $0.originalText == piece.text
                }
                if exists { continue }
                elements.append(.existingText(
                    page: currentPage,
                    rect: piece.rect,
                    text: piece.text,
                    zIndex: z,
                    fontName: piece.fontName,
                    fontSize: piece.fontSize,
                    isBold: piece.isBold,
                    isItalic: piece.isItalic,
                    isUnderline: piece.isUnderline,
                    colorHex: piece.colorHex,
                    paperHex: DocumentEditorService.shared.paperHex(in: image, around: piece.rect)
                ))
                z += 1
            }
        }
        nextZ = z
        let detected = DocumentEditorService.shared.detectFormFields(from: blocks, page: currentPage)
        formFields.removeAll { $0.pageIndex == currentPage }
        formFields.append(contentsOf: detected)
        isRecognizing = false
    }

    // MARK: - Supporting chrome

    private var pageBar: some View {
        HStack {
            Button {
                AppAnalytics.tap("editor_prev_page")
                currentPage = max(currentPage - 1, 0)
            } label: {
                Image(systemName: "chevron.left.circle.fill").font(.title3)
            }
            .disabled(currentPage <= 0)
            Text("Page \(currentPage + 1) of \(pages.count)")
                .font(.subheadline.weight(.semibold))
            Button {
                AppAnalytics.tap("editor_next_page")
                currentPage = min(currentPage + 1, pages.count - 1)
            } label: {
                Image(systemName: "chevron.right.circle.fill").font(.title3)
            }
            .disabled(currentPage >= pages.count - 1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func selectionActions(for item: EditorElement) -> some View {
        HStack(spacing: 10) {
            actionChip("Copy", "doc.on.doc") { copySelected() }
            actionChip("Front", "square.3.layers.3d") { bringToFront() }
            actionChip("Back", "square.3.layers.3d.bottom.filled") { sendToBack() }
            Spacer()
            Button {
                deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(DocumentEditorPalette.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DocumentEditorPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private func actionChip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
            .foregroundColor(.primary)
            .frame(width: 58, height: 46)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var fontPicker: some View {
        NavigationStack {
            List(DocumentEditorPalette.fonts, id: \.self) { font in
                Button {
                    AppAnalytics.tap("editor_font_select", ["font": font])
                    updateSelected { $0.fontName = font }
                    showFontPicker = false
                } label: {
                    HStack {
                        Text(font).font(.custom(font, size: 18)).foregroundColor(.primary)
                        Spacer()
                        if selected?.fontName == font {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Font")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: AppAnalytics.action("editor_font_done") { showFontPicker = false })
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct EditorZoomScrollView<Content: View>: UIViewRepresentable {
    var contentSize: CGSize
    var panEnabled: Bool
    var pinchEnabled: Bool
    @Binding var zoomScale: CGFloat
    var resetToken: Int
    var focusToken: Int
    var focusRect: CGRect?
    var bottomInset: CGFloat
    var zoomRequest: CGFloat
    var zoomRequestToken: Int
    var oneFingerSelectsText: Bool
    var onTextDrag: ((CGPoint, CGPoint, Bool) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var content: Content

    init(
        contentSize: CGSize,
        panEnabled: Bool,
        pinchEnabled: Bool,
        zoomScale: Binding<CGFloat>,
        resetToken: Int,
        focusToken: Int,
        focusRect: CGRect?,
        bottomInset: CGFloat,
        zoomRequest: CGFloat,
        zoomRequestToken: Int,
        oneFingerSelectsText: Bool = false,
        onTextDrag: ((CGPoint, CGPoint, Bool) -> Void)? = nil,
        onTap: ((CGPoint) -> Void)?,
        @ViewBuilder content: () -> Content
    ) {
        self.contentSize = contentSize
        self.panEnabled = panEnabled
        self.pinchEnabled = pinchEnabled
        self._zoomScale = zoomScale
        self.resetToken = resetToken
        self.focusToken = focusToken
        self.focusRect = focusRect
        self.bottomInset = bottomInset
        self.zoomRequest = zoomRequest
        self.zoomRequestToken = zoomRequestToken
        self.oneFingerSelectsText = oneFingerSelectsText
        self.onTextDrag = onTextDrag
        self.onTap = onTap
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.bouncesZoom = true
        scroll.backgroundColor = .clear
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false

        let host = context.coordinator.hostingController
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.insetsLayoutMarginsFromSafeArea = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(host.view)

        let width = host.view.widthAnchor.constraint(equalToConstant: max(contentSize.width, 1))
        let height = host.view.heightAnchor.constraint(equalToConstant: max(contentSize.height, 1))
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            width,
            height
        ])
        context.coordinator.widthConstraint = width
        context.coordinator.heightConstraint = height

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)
        context.coordinator.singleTap = singleTap
        context.coordinator.doubleTap = doubleTap

        let selectPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSelectPan(_:)))
        selectPan.minimumNumberOfTouches = 1
        selectPan.maximumNumberOfTouches = 1
        selectPan.delegate = context.coordinator
        scroll.addGestureRecognizer(selectPan)
        context.coordinator.selectPan = selectPan
        singleTap.require(toFail: selectPan)

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.hostingController.rootView = content
        context.coordinator.widthConstraint?.constant = max(contentSize.width, 1)
        context.coordinator.heightConstraint?.constant = max(contentSize.height, 1)
        scroll.maximumZoomScale = 8
        scroll.panGestureRecognizer.isEnabled = panEnabled
        scroll.panGestureRecognizer.minimumNumberOfTouches = oneFingerSelectsText ? 2 : 1
        scroll.pinchGestureRecognizer?.isEnabled = pinchEnabled
        context.coordinator.selectPan?.isEnabled = oneFingerSelectsText && onTextDrag != nil
        context.coordinator.singleTap?.isEnabled = onTap != nil
        context.coordinator.doubleTap?.isEnabled = pinchEnabled
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            context.coordinator.lastFocusToken = focusToken
            if scroll.zoomScale != 1 {
                scroll.setZoomScale(1, animated: false)
            }
            context.coordinator.centerContent(in: scroll)
        } else if context.coordinator.lastFocusToken != focusToken, let rect = focusRect {
            context.coordinator.lastFocusToken = focusToken
            let inset = bottomInset
            DispatchQueue.main.async {
                context.coordinator.zoomTo(rect, in: scroll, bottomInset: inset, animated: true)
            }
        } else if context.coordinator.lastZoomRequestToken != zoomRequestToken {
            context.coordinator.lastZoomRequestToken = zoomRequestToken
            scroll.setZoomScale(min(max(zoomRequest, scroll.minimumZoomScale), scroll.maximumZoomScale), animated: true)
        } else if scroll.zoomScale <= 1.02 {
            context.coordinator.centerContent(in: scroll)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: EditorZoomScrollView
        let hostingController: UIHostingController<Content>
        var widthConstraint: NSLayoutConstraint?
        var heightConstraint: NSLayoutConstraint?
        var singleTap: UITapGestureRecognizer?
        var doubleTap: UITapGestureRecognizer?
        var selectPan: UIPanGestureRecognizer?
        var isUserZooming = false
        var lastResetToken = -1
        var lastFocusToken = -1
        var lastZoomRequestToken = 0

        init(_ parent: EditorZoomScrollView) {
            self.parent = parent
            self.hostingController = UIHostingController(rootView: parent.content)
            super.init()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isUserZooming = true
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.zoomScale = scrollView.zoomScale
            if scrollView.zoomScale <= 1.02 {
                centerContent(in: scrollView)
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isUserZooming = false
            parent.zoomScale = scale
            if scale <= 1.02 {
                centerContent(in: scrollView)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === selectPan && otherGestureRecognizer is UIPinchGestureRecognizer
                || otherGestureRecognizer === selectPan && gestureRecognizer is UIPinchGestureRecognizer
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === selectPan,
                  let scroll = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scroll.panGestureRecognizer
        }

        @objc func handleSelectPan(_ recognizer: UIPanGestureRecognizer) {
            guard !isUserZooming, let callback = parent.onTextDrag else { return }
            let current = recognizer.location(in: hostingController.view)
            let translation = recognizer.translation(in: hostingController.view)
            let start = CGPoint(x: current.x - translation.x, y: current.y - translation.y)
            let ended = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
            callback(start, current, ended)
        }

        func centerContent(in scrollView: UIScrollView) {
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
            scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
        }

        func zoomTo(_ rect: CGRect, in scroll: UIScrollView, bottomInset: CGFloat, animated: Bool) {
            let bounds = scroll.bounds
            guard bounds.width > 1, bounds.height > 1, rect.width > 1, rect.height > 1 else { return }
            let visibleHeight = max(120, bounds.height - bottomInset)
            let scale = min(
                bounds.width / rect.width,
                visibleHeight / rect.height,
                scroll.maximumZoomScale
            )
            let finalScale = min(max(scale, 1.35), scroll.maximumZoomScale)
            let apply = {
                scroll.setZoomScale(finalScale, animated: false)
                scroll.layoutIfNeeded()
                self.centerContent(in: scroll)
                var offset = CGPoint(
                    x: rect.midX * finalScale - bounds.width / 2,
                    y: rect.midY * finalScale - visibleHeight * 0.38
                )
                let minX = -scroll.contentInset.left
                let minY = -scroll.contentInset.top
                let maxX = max(minX, scroll.contentSize.width - bounds.width + scroll.contentInset.right)
                let maxY = max(minY, scroll.contentSize.height - bounds.height + scroll.contentInset.bottom)
                offset.x = min(max(minX, offset.x), maxX)
                offset.y = min(max(minY, offset.y), maxY)
                scroll.setContentOffset(offset, animated: false)
                self.parent.zoomScale = scroll.zoomScale
            }
            if animated {
                UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: apply)
            } else {
                apply()
            }
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            parent.onTap?(recognizer.location(in: hostingController.view))
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.08 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: hostingController.view)
                let rect = CGRect(x: point.x - 50, y: point.y - 50, width: 100, height: 100)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}

private enum PrintedSelectionScope {
    case sentence
    case paragraph
}

private struct EditTextPanel: View {
    let element: EditorElement
    @Binding var expanded: Bool
    var changeSummary: String?
    let onChange: ((inout EditorElement) -> Void) -> Void
    let onCopy: () -> Void
    let onFront: () -> Void
    let onBack: () -> Void
    let onDelete: () -> Void
    let onPickFont: () -> Void
    var onPlace: ((TextPlacement) -> Void)?
    var onExpand: ((PrintedSelectionScope) -> Void)? = nil
    @FocusState private var isFocused: Bool

    private var pointSize: Double {
        Double(max(8, min(96, element.fontSize * 800)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                AppAnalytics.tap(expanded ? "editor_text_collapse" : "editor_text_expand")
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(element.sourceID == nil ? "Edit Text" : "Edited Text")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if !element.originalText.isEmpty, element.sourceID != nil {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle")
                    Text("Original: \(element.originalText)")
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            HStack {
                TextField(element.sourceID == nil ? "Type here" : "Type edited text", text: Binding(
                    get: { element.text },
                    set: { value in onChange { $0.text = value; $0.isModified = true } }
                ))
                .textFieldStyle(.plain)
                .font(.custom(element.fontName, size: 17))
                .bold(element.isBold)
                .italic(element.isItalic)
                .focused($isFocused)
                Button {
                    AppAnalytics.tap("editor_text_clear")
                    onChange { $0.text = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))

            if let onPlace {
                HStack(spacing: 6) {
                    ForEach(TextPlacement.allCases) { placement in
                        Button {
                            onPlace(placement)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: placement.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(placement.title)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if element.kind == .existingText, let onExpand {
                    HStack(spacing: 6) {
                        Button("Sentence") { onExpand(.sentence) }
                        Button("Paragraph") { onExpand(.paragraph) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
                }
                Text(element.kind == .existingText
                 ? "Drag from the first word to the last, or tap Sentence or Paragraph."
                 : "Drag the box to move · Pinch to resize text")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if expanded {
                HStack(spacing: 10) {
                    Button(action: onPickFont) {
                        HStack(spacing: 4) {
                            Text(element.fontName).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(DocumentEditorPalette.accent)
                    }
                    Slider(
                        value: Binding(
                            get: { pointSize },
                            set: { newValue in onChange { $0.fontSize = CGFloat(newValue) / 800 } }
                        ),
                        in: 8...96
                    )
                    Text("\(Int(pointSize)) pt")
                        .font(.caption.weight(.semibold))
                        .frame(width: 40, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    styleButton("bold", selected: element.isBold) {
                        AppAnalytics.tap("editor_text_style", ["style": "bold"])
                        onChange { $0.isBold.toggle() }
                    }
                    styleButton("italic", selected: element.isItalic) {
                        AppAnalytics.tap("editor_text_style", ["style": "italic"])
                        onChange { $0.isItalic.toggle() }
                    }
                    styleButton("underline", selected: element.isUnderline) {
                        AppAnalytics.tap("editor_text_style", ["style": "underline"])
                        onChange { $0.isUnderline.toggle() }
                    }
                    alignButton("text.alignleft", 0)
                    alignButton("text.aligncenter", 1)
                    alignButton("text.alignright", 2)
                    Spacer(minLength: 4)
                    ForEach(DocumentEditorPalette.editColors, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(
                                    hex == "#FFFFFF" ? Color.secondary.opacity(0.4) : Color.clear,
                                    lineWidth: 1
                                )
                            )
                            .overlay(
                                Circle().strokeBorder(element.colorHex == hex ? DocumentEditorPalette.accent : Color.clear, lineWidth: 2)
                            )
                            .onTapGesture {
                                AppAnalytics.tap("editor_text_color", ["color": hex])
                                onChange { $0.colorHex = hex }
                            }
                    }
                }

                HStack(spacing: 8) {
                    iconAction("doc.on.doc", onCopy)
                    iconAction("square.3.layers.3d", onFront)
                    iconAction("square.3.layers.3d.bottom.filled", onBack)
                    Slider(
                        value: Binding(
                            get: { element.rotation },
                            set: { value in onChange { $0.rotation = value } }
                        ),
                        in: -180...180
                    )
                    Text("\(Int(element.rotation))°")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 28, alignment: .trailing)
                    Spacer()
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(DocumentEditorPalette.accent)
                            .frame(width: 34, height: 30)
                            .background(DocumentEditorPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(.systemBackground))
        .onAppear {
            isFocused = true
        }
        .onChange(of: element.id) { _, _ in
            isFocused = true
        }
    }

    private func styleButton(_ icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(selected ? .white : .primary)
                .frame(width: 30, height: 28)
                .background(selected ? DocumentEditorPalette.accent : Color(.systemGray5), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func alignButton(_ icon: String, _ value: Int) -> some View {
        Button {
            AppAnalytics.tap("editor_text_align", ["align": value])
            onChange { $0.alignment = value }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(element.alignment == value ? DocumentEditorPalette.accent : .primary)
                .frame(width: 28, height: 28)
                .background(element.alignment == value ? DocumentEditorPalette.accent.opacity(0.12) : Color(.systemGray5), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func iconAction(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 34, height: 30)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct DocumentEditorLaunchRow: View {
    var onEdit: (() -> Void)?
    var onHighlight: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if let onEdit {
                Button(action: onEdit) {
                    Label("Edit Document", systemImage: "pencil")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.systemGray6))
                        .cornerRadius(14)
                }
            }
            if let onHighlight {
                Button(action: onHighlight) {
                    Label("Highlight", systemImage: "highlighter")
                        .font(.headline)
                        .foregroundColor(DocumentEditorPalette.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(DocumentEditorPalette.accent.opacity(0.12))
                        .cornerRadius(14)
                }
            }
        }
    }
}

