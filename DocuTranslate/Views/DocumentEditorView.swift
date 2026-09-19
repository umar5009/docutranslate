import SwiftUI
import PhotosUI

struct DocumentEditorView: View {
    @State private var pages: [UIImage]
    @State private var currentPage: Int
    let fileName: String
    let documentID: UUID
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

    init(
        pages: [UIImage],
        pageIndex: Int = 0,
        fileName: String,
        documentID: UUID,
        initialMode: DocumentEditorMode = .edit,
        onComplete: @escaping ([UIImage]) -> Void
    ) {
        _pages = State(initialValue: pages)
        _currentPage = State(initialValue: min(max(pageIndex, 0), max(pages.count - 1, 0)))
        self.fileName = fileName
        self.documentID = documentID
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
        elements.filter { $0.pageIndex == currentPage }.sorted { $0.zIndex < $1.zIndex }
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
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topBar
                if mode == .edit {
                    editToolbar
                } else {
                    markupToolbar
                }
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
            bottomChrome
                .padding(.bottom, keyboardHeight)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .photosPicker(isPresented: $showImagePicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            Task { await addPickedImage(item) }
        }
        .confirmationDialog("Shape", isPresented: $showShapePicker, titleVisibility: .visible) {
            ForEach(EditorShapeKind.allCases) { kind in
                Button(kind.title) {
                    shapeKind = kind
                    editTool = .shape
                }
            }
        }
        .alert("Add Link", isPresented: $showLinkAlert) {
            TextField("https://", text: $linkURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            Button("Add") { commitLink() }
            Button("Cancel", role: .cancel) { pendingLinkRect = nil }
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
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
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
            zoomScale = 1
            zoomResetToken += 1
            zoomFocusRect = nil
            Task { await recognizeCurrentPage() }
        }
        .onChange(of: selectedID) { _, id in
            if let item = selected {
                focusOnNormalizedRect(item.rect)
            }
        }
        .onChange(of: keyboardHeight) { old, new in
            if old < 50, new >= 50, selected?.isText == true {
                inspectorExpanded = false
                if let item = selected {
                    focusOnNormalizedRect(item.rect)
                }
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
                onPickFont: { showFontPicker = true }
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
        var inset = keyboardHeight
        if selected?.isText == true {
            inset += inspectorExpanded ? 210 : 112
        } else if selected != nil {
            inset += 64
        }
        return inset
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
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(undoStack.isEmpty)
            .foregroundColor(undoStack.isEmpty ? .secondary : DocumentEditorPalette.accent)

            if mode == .edit {
                Button {
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

    private var canvasAllowsPan: Bool {
        if mode == .markup {
            return selected?.isText == true
        }
        switch editTool {
        case .select:
            return selectedID == nil || selected?.isText == true
        case .text, .image:
            return true
        case .shape, .link, .redact:
            return false
        }
    }

    private var usesDrawingDrag: Bool {
        if mode == .markup {
            return selected?.isText != true
        }
        switch editTool {
        case .shape, .link, .redact:
            return true
        case .select:
            return selectedID != nil && selected?.isText != true
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
                    panEnabled: canvasAllowsPan,
                    zoomScale: $zoomScale,
                    resetToken: zoomResetToken,
                    focusToken: zoomFocusToken,
                    focusRect: zoomFocusRect,
                    bottomInset: zoomBottomInset,
                    onTap: canvasAllowsPan ? { point in handleCanvasTap(at: point) } : nil
                ) {
                    pageCanvas(size: fit)
                        .onAppear { canvasSize = fit }
                        .onChange(of: fit) { _, size in canvasSize = size }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if zoomScale > 1.05 {
                    Button {
                        zoomScale = 1
                        zoomResetToken += 1
                    } label: {
                        Text(String(format: "%.1f×  ·  Reset", zoomScale))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                }
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
    }

    private func fittedPageSize(in bounds: CGSize) -> CGSize {
        let imageSize = pageImage.size
        let available = CGSize(width: max(bounds.width - 12, 1), height: max(bounds.height - 12, 1))
        guard imageSize.width > 1, imageSize.height > 1 else { return available }
        let ratio = min(available.width / imageSize.width, available.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
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
            if usesDrawingDrag {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(canvasGesture)
            }
            if mode == .edit, editTool == .select {
                formFieldHints
            }
            connectorArrows
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
                    textBlock(element, in: rect)
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
            if isSelected, element.kind != .ink {
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

    private func textBlock(_ element: EditorElement, in rect: CGRect) -> some View {
        Text(element.text)
            .font(.custom(element.fontName, size: max(8, element.fontSize * canvasSize.height)))
            .bold(element.isBold)
            .italic(element.isItalic)
            .underline(element.isUnderline)
            .foregroundColor(Color(hex: element.colorHex))
            .multilineTextAlignment(element.alignment == 1 ? .center : element.alignment == 2 ? .trailing : .leading)
            .frame(width: rect.width, height: rect.height, alignment: element.alignment == 1 ? .center : element.alignment == 2 ? .trailing : .leading)
            .minimumScaleFactor(0.5)
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
                    .frame(width: 8, height: 8)
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

    private func hitTest(at point: CGPoint) -> UUID? {
        for element in pageElements.reversed() {
            if element.kind == .ink {
                if inkHits(element, at: point) { return element.id }
                continue
            }
            let rect = element.rect.pixelRect(in: canvasSize).insetBy(dx: -6, dy: -6)
            if rect.contains(point) { return element.id }
        }
        return nil
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
            Text("Pinch to zoom, then tap a field to fill text, date, or signature")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private func handleSelectTap(at point: CGPoint) {
        if let id = hitTest(at: point), let element = elements.first(where: { $0.id == id }) {
            let isPrintedLabel = element.kind == .existingText
                && DocumentEditorService.shared.isFieldLabel(element.text)
            if !isPrintedLabel {
                if element.kind == .existingText {
                    beginLinkedEdit(from: element)
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
            insertText(in: field.rect, text: "")
        case .date:
            pickedDate = Date()
            showDatePicker = true
        case .signature:
            showSignatureCapture = true
        case .checkbox:
            toggleCheckbox(field)
        }
    }

    private func insertText(in rect: CGRect, text: String) {
        pushUndo()
        let element = EditorElement.addedText(
            page: currentPage,
            rect: rect.clampedNormalized(),
            zIndex: nextZ,
            text: text,
            fontSize: max(0.016, rect.height * 0.72)
        )
        nextZ += 1
        elements.append(element)
        selectedID = element.id
        inspectorExpanded = false
        editTool = .select
    }

    private func insertDate() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let text = formatter.string(from: pickedDate)
        if let field = pendingField {
            insertText(in: field.rect, text: text)
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
        insertText(in: field.rect, text: "✓")
        pendingField = nil
    }

    private var datePickerSheet: some View {
        NavigationView {
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
                        showDatePicker = false
                        pendingField = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") { insertDate() }
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
        guard let id = hitTest(at: point),
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
        element.originalText = source.text
        element.fillHex = "#FFFBEB"
        element.colorHex = "#9A3412"
        nextZ += 1
        elements.append(element)
        selectedID = element.id
        inspectorExpanded = false
        focusOnNormalizedRect(source.rect.union(rect).insetBy(dx: -0.02, dy: -0.02))
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
    }

    private func copySelected() {
        guard var item = selected else { return }
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
        pushUndo()
        elements[idx].zIndex = nextZ
        nextZ += 1
    }

    private func sendToBack() {
        guard let idx = selectedIndex else { return }
        pushUndo()
        let minZ = (elements.map(\.zIndex).min() ?? 0) - 1
        elements[idx].zIndex = minZ
    }

    private func deleteSelected() {
        guard let id = selectedID, let idx = selectedIndex else { return }
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
            let exists = elements.contains {
                $0.pageIndex == currentPage && $0.kind == .existingText && $0.rect.intersects(block.rect.insetBy(dx: 0.002, dy: 0.002)) && $0.originalText == block.text
            }
            if exists { continue }
            elements.append(.existingText(page: currentPage, rect: block.rect, text: block.text, zIndex: z))
            z += 1
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
                currentPage = max(currentPage - 1, 0)
            } label: {
                Image(systemName: "chevron.left.circle.fill").font(.title3)
            }
            .disabled(currentPage <= 0)
            Text("Page \(currentPage + 1) of \(pages.count)")
                .font(.subheadline.weight(.semibold))
            Button {
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
        NavigationView {
            List(DocumentEditorPalette.fonts, id: \.self) { font in
                Button {
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
                    Button("Done") { showFontPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct EditorZoomScrollView<Content: View>: UIViewRepresentable {
    var contentSize: CGSize
    var panEnabled: Bool
    @Binding var zoomScale: CGFloat
    var resetToken: Int
    var focusToken: Int
    var focusRect: CGRect?
    var bottomInset: CGFloat
    var onTap: ((CGPoint) -> Void)?
    var content: Content

    init(
        contentSize: CGSize,
        panEnabled: Bool,
        zoomScale: Binding<CGFloat>,
        resetToken: Int,
        focusToken: Int,
        focusRect: CGRect?,
        bottomInset: CGFloat,
        onTap: ((CGPoint) -> Void)?,
        @ViewBuilder content: () -> Content
    ) {
        self.contentSize = contentSize
        self.panEnabled = panEnabled
        self._zoomScale = zoomScale
        self.resetToken = resetToken
        self.focusToken = focusToken
        self.focusRect = focusRect
        self.bottomInset = bottomInset
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
        scroll.maximumZoomScale = 6
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

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.hostingController.rootView = content
        context.coordinator.widthConstraint?.constant = max(contentSize.width, 1)
        context.coordinator.heightConstraint?.constant = max(contentSize.height, 1)
        scroll.panGestureRecognizer.isEnabled = panEnabled
        context.coordinator.singleTap?.isEnabled = onTap != nil
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
        } else {
            context.coordinator.centerContent(in: scroll)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: EditorZoomScrollView
        let hostingController: UIHostingController<Content>
        var widthConstraint: NSLayoutConstraint?
        var heightConstraint: NSLayoutConstraint?
        var singleTap: UITapGestureRecognizer?
        var lastResetToken = -1
        var lastFocusToken = -1

        init(_ parent: EditorZoomScrollView) {
            self.parent = parent
            self.hostingController = UIHostingController(rootView: parent.content)
            super.init()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.zoomScale = scrollView.zoomScale
            centerContent(in: scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            parent.zoomScale = scale
            centerContent(in: scrollView)
        }

        func centerContent(in scrollView: UIScrollView) {
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
            scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
        }

        func zoomTo(_ rect: CGRect, in scroll: UIScrollView, bottomInset: CGFloat, animated: Bool) {
            let bounds = scroll.bounds
            guard bounds.width > 1, bounds.height > 1, rect.width > 1, rect.height > 1 else { return }
            let visibleHeight = max(160, bounds.height - bottomInset)
            let scale = min(
                bounds.width / rect.width,
                visibleHeight / rect.height,
                scroll.maximumZoomScale
            )
            let finalScale = min(max(scale, 1.15), scroll.maximumZoomScale)
            let apply = {
                scroll.setZoomScale(finalScale, animated: false)
                scroll.layoutIfNeeded()
                var offset = CGPoint(
                    x: rect.midX * finalScale - bounds.width / 2,
                    y: rect.midY * finalScale - visibleHeight / 2
                )
                let maxX = max(0, scroll.contentSize.width - bounds.width)
                let maxY = max(0, scroll.contentSize.height - bounds.height)
                offset.x = min(max(-scroll.contentInset.left, offset.x), maxX)
                offset.y = min(max(-scroll.contentInset.top, offset.y), maxY)
                scroll.setContentOffset(offset, animated: false)
                self.parent.zoomScale = scroll.zoomScale
                self.centerContent(in: scroll)
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
    @FocusState private var isFocused: Bool

    private var pointSize: Double {
        Double(max(8, min(96, element.fontSize * 800)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Text("Edit Text")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            HStack {
                TextField("Type here", text: Binding(
                    get: { element.text },
                    set: { value in onChange { $0.text = value; $0.isModified = true } }
                ))
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isFocused)
                Button {
                    onChange { $0.text = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))

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
                    styleButton("bold", selected: element.isBold) { onChange { $0.isBold.toggle() } }
                    styleButton("italic", selected: element.isItalic) { onChange { $0.isItalic.toggle() } }
                    styleButton("underline", selected: element.isUnderline) { onChange { $0.isUnderline.toggle() } }
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
                            .onTapGesture { onChange { $0.colorHex = hex } }
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
            if element.text.isEmpty {
                isFocused = true
            }
        }
        .onChange(of: element.id) { _, _ in
            if element.text.isEmpty {
                isFocused = true
            }
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

