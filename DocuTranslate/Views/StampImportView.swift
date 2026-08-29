import SwiftUI
import PhotosUI
import PencilKit

struct StampImportView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var sourceImage: UIImage?
    @State private var cleanedPhoto: UIImage?
    @State private var generatedStamp: UIImage?
    @State private var recognizedText = ""
    @State private var inkColor = StampStyle.inkRed
    @State private var useRecognizedText = true
    @State private var isProcessing = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var shouldSave = true
    @State private var stampName = ""
    @State private var savedStamps: [SavedStamp] = []
    @State private var cropSession: StampCropSession?
    @State private var originalCapture: UIImage?

    let onComplete: (UIImage?) -> Void

    private let service = SignStampService.shared

    private var previewImage: UIImage? {
        if useRecognizedText, !(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return generatedStamp
        }
        return cleanedPhoto
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if sourceImage == nil {
                        infoBanner
                        importOptions
                        savedStampsSection
                    } else {
                        previewSection
                        recognitionSection
                        processingControls
                    }
                }
                .padding()
            }
            .navigationTitle("Import Stamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(sourceImage == nil ? "Cancel" : "Back") {
                        AppAnalytics.tap(sourceImage == nil ? "stamp_import_cancel" : "stamp_import_back")
                        if sourceImage != nil {
                            resetImport()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Use Stamp", action: AppAnalytics.action("stamp_import_use") { finish() })
                        .font(.headline)
                        .disabled(previewImage == nil || isProcessing)
                }
            }
            .onAppear { savedStamps = service.loadSavedStamps() }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        await MainActor.run { beginCrop(img, source: "photos") }
                    }
                    await MainActor.run { photoItem = nil }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView { image in
                    showCamera = false
                    if let image {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            beginCrop(image, source: "camera")
                        }
                    }
                }
            }
            .fullScreenCover(item: $cropSession) { session in
                StampCropView(
                    image: session.image,
                    onCancel: {
                        cropSession = nil
                        if sourceImage == nil {
                            originalCapture = nil
                        }
                    },
                    onCrop: { cropped in
                        cropSession = nil
                        loadImage(cropped)
                    }
                )
            }
        }
    }

    private var infoBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Photograph a stamp, then we recreate it", systemImage: "text.viewfinder")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.blue)

            Text("Take a photo of a stamped page, crop to the stamp, then the app cleans it for reuse.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.blue.opacity(0.08))
        .cornerRadius(12)
    }

    private var importOptions: some View {
        VStack(spacing: 12) {
            Button {
                AppAnalytics.tap("stamp_import_camera")
                showCamera = true
            } label: {
                importRow(icon: "camera.fill", title: "Photograph Stamp", subtitle: "Capture CANCELLED or any custom stamp", color: .blue)
            }

            Button {
                AppAnalytics.tap("stamp_import_photos")
                showPhotoPicker = true
            } label: {
                importRow(icon: "photo.on.rectangle", title: "Choose from Photos", subtitle: "Import an existing stamp image", color: .green)
            }
        }
    }

    private func importRow(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    @ViewBuilder
    private var savedStampsSection: some View {
        if !savedStamps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saved Stamps")
                    .font(.headline)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(savedStamps) { saved in
                            if let img = saved.image {
                                Button {
                                    AppAnalytics.tap("stamp_import_saved", ["name": saved.name])
                                    onComplete(img)
                                    dismiss()
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 72, height: 72)
                                            .padding(8)
                                            .background(Color(.systemGray6))
                                            .cornerRadius(12)
                                        Text(saved.name)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .frame(width: 88)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.headline)

            ZStack {
                CheckerboardBackground()
                if isProcessing {
                    ProgressView("Reading stamp…")
                } else if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.systemGray4)))
        }
    }

    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $useRecognizedText) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create a clean stamp from text")
                    Text(recognizedText.isEmpty ? "No text detected — you can type it below" : "Detected: \(recognizedText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: useRecognizedText) { _ in refreshGenerated() }

            TextField("Stamp text (e.g. CANCELLED)", text: $recognizedText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .onChange(of: recognizedText) { _ in
                    if stampName.isEmpty || stampName == "My Stamp" {
                        let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { stampName = trimmed.capitalized }
                    }
                    refreshGenerated()
                }

            HStack(spacing: 10) {
                Text("Ink")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(StampStyle.inkChoices, id: \.0) { name, color in
                    Circle()
                        .fill(Color(uiColor: color))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle().strokeBorder(inkColor.isClose(to: color) ? Color.primary : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture {
                            AppAnalytics.tap("stamp_import_ink", ["color": name])
                            inkColor = color
                            refreshGenerated()
                        }
                        .accessibilityLabel(name)
                }
            }
        }
    }

    private var processingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                AppAnalytics.tap("stamp_import_crop")
                if let originalCapture {
                    cropSession = StampCropSession(image: originalCapture)
                } else if let sourceImage {
                    cropSession = StampCropSession(image: sourceImage)
                }
            } label: {
                Label("Crop photo", systemImage: "crop")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(originalCapture == nil && sourceImage == nil)

            TextField("Save as name", text: $stampName)
                .textFieldStyle(.roundedBorder)

            Toggle(isOn: $shouldSave) {
                Text("Save stamp for future use")
            }
        }
    }

    private func beginCrop(_ image: UIImage, source: String) {
        originalCapture = image
        cropSession = StampCropSession(image: image)
        AppAnalytics.log("stamp_photo_captured", ["source": source])
    }

    private func loadImage(_ image: UIImage) {
        sourceImage = image
        cleanedPhoto = nil
        generatedStamp = nil
        recognizedText = ""
        isProcessing = true

        Task {
            let result = await service.interpretStampImage(image)
            await MainActor.run {
                cleanedPhoto = result.cleanedImage
                inkColor = result.inkColor
                recognizedText = result.recognizedText
                useRecognizedText = service.shouldRecreateFromOCR(result.recognizedText)
                if stampName.isEmpty {
                    stampName = result.recognizedText.isEmpty ? "My Stamp" : result.recognizedText.capitalized
                }
                isProcessing = false
                refreshGenerated()
            }
        }
    }

    private func refreshGenerated() {
        let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            generatedStamp = nil
            return
        }
        let preset = StampStyle.presets.first { $0.0.compare(text, options: .caseInsensitive) == .orderedSame }?.1
        let style = StampStyle(color: inkColor, fontSize: preset?.fontSize ?? 20, shape: preset?.shape ?? .roundedRect)
        generatedStamp = service.makeStamp(text: text, style: style)
    }

    private func resetImport() {
        sourceImage = nil
        cleanedPhoto = nil
        generatedStamp = nil
        recognizedText = ""
        isProcessing = false
        stampName = ""
        useRecognizedText = true
        originalCapture = nil
        cropSession = nil
    }

    private func finish() {
        guard let previewImage else { return }
        if shouldSave {
            let name = stampName.trimmingCharacters(in: .whitespacesAndNewlines)
            service.saveStamp(previewImage, name: name.isEmpty ? "My Stamp" : name)
        }
        AppAnalytics.log("stamp_used", [
            "source": useRecognizedText ? "ocr" : "photo",
            "saved": shouldSave ? "true" : "false"
        ])
        onComplete(previewImage)
        dismiss()
    }
}

// MARK: - Draw Stamp

struct FullScreenStampDrawView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var canvasView = PKCanvasView()
    @State private var inkColor: Color = Color(uiColor: StampStyle.inkRed)
    @State private var stampText = ""
    @State private var generated: UIImage?
    @State private var drawn: UIImage?
    @State private var useTyped = true
    @State private var isRecognizing = false
    @State private var shouldSave = true

    let onComplete: (UIImage?) -> Void

    private let service = SignStampService.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                Text("Type a stamp such as CANCELLED, or write it by hand")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                TextField("Stamp text", text: $stampText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .padding(.horizontal)
                    .onChange(of: stampText) { _ in
                        useTyped = !stampText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        refreshTyped()
                    }

                if useTyped, let generated {
                    Image(uiImage: generated)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 72)
                        .frame(maxWidth: .infinity)
                        .background(CheckerboardBackground())
                        .cornerRadius(10)
                        .padding(.horizontal)
                }

                ZStack(alignment: .topTrailing) {
                    SignatureCanvasView(canvasView: $canvasView, inkColor: UIColor(inkColor))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Color(.systemGray3), lineWidth: 1)
                        )

                    HStack {
                        Button("Recognize writing") {
                            AppAnalytics.tap("stamp_draw_recognize")
                            recognizeDrawing()
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(canvasView.drawing.strokes.isEmpty || isRecognizing)

                        Spacer()

                        Button {
                            AppAnalytics.tap("stamp_draw_clear")
                            canvasView.drawing = PKDrawing()
                            drawn = nil
                        } label: {
                            Label("Clear", systemImage: "arrow.counterclockwise")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(12)
                }
                .padding(.horizontal)

                if isRecognizing {
                    ProgressView("Reading handwriting…")
                        .font(.caption)
                }

                HStack(spacing: 12) {
                    Text("Ink")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    ForEach(Array(StampStyle.inkChoices.prefix(5)), id: \.0) { _, color in
                        Circle()
                            .fill(Color(uiColor: color))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle().strokeBorder(inkColor == Color(uiColor: color) ? Color.blue : Color.clear, lineWidth: 3)
                            )
                            .onTapGesture {
                                AppAnalytics.tap("stamp_draw_ink")
                                inkColor = Color(uiColor: color)
                                refreshTyped()
                            }
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)

                Toggle(isOn: $shouldSave) {
                    Text("Save stamp for future use")
                        .font(.subheadline)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Write Stamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: AppAnalytics.action("stamp_draw_cancel") { dismiss() })
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Use Stamp", action: AppAnalytics.action("stamp_draw_use") { finish() })
                        .font(.headline)
                        .disabled(!canFinish)
                }
            }
            .onAppear { configureCanvas() }
            .onChange(of: inkColor) { _ in configureCanvas() }
        }
    }

    private var canFinish: Bool {
        !stampText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canvasView.drawing.strokes.isEmpty
    }

    private func configureCanvas() {
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: UIColor(inkColor), width: 5)
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true
    }

    private func refreshTyped() {
        let text = stampText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            generated = nil
            return
        }
        let preset = StampStyle.presets.first { $0.0.compare(text, options: .caseInsensitive) == .orderedSame }?.1
        generated = service.makeStamp(
            text: text,
            style: StampStyle(color: UIColor(inkColor), fontSize: preset?.fontSize ?? 20, shape: preset?.shape ?? .roundedRect)
        )
    }

    private func recognizeDrawing() {
        guard let image = service.signatureFromCanvas(canvasView) else { return }
        isRecognizing = true
        Task {
            let text = await service.recognizeStampText(in: image)
            await MainActor.run {
                isRecognizing = false
                if !text.isEmpty {
                    stampText = text
                    useTyped = true
                    refreshTyped()
                }
            }
        }
    }

    private func finish() {
        Task {
            var typed = stampText.trimmingCharacters(in: .whitespacesAndNewlines)
            if typed.isEmpty, let drawing = service.signatureFromCanvas(canvasView) {
                let recognized = await service.recognizeStampText(in: drawing)
                if !recognized.isEmpty {
                    typed = recognized
                    await MainActor.run {
                        stampText = recognized
                        useTyped = true
                        refreshTyped()
                    }
                }
            }

            await MainActor.run {
                commitStamp(typedText: typed)
            }
        }
    }

    private func commitStamp(typedText: String) {
        var image: UIImage?
        var name = "My Stamp"

        if !typedText.isEmpty {
            refreshTyped()
            image = generated ?? service.makeStamp(
                text: typedText,
                style: StampStyle(color: UIColor(inkColor), fontSize: 20)
            )
            name = typedText.capitalized
        } else if let drawing = service.stampFromCanvas(canvasView) {
            image = drawing
        }

        guard let image else { return }
        if shouldSave { service.saveStamp(image, name: name) }
        onComplete(image)
        dismiss()
    }
}

// MARK: - Camera

struct StampCropSession: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onCapture(image)
        }
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            for row in 0..<Int(ceil(size.height / tile)) {
                for col in 0..<Int(ceil(size.width / tile)) {
                    let rect = CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                    let shade = (row + col).isMultiple(of: 2) ? Color(.systemGray5) : Color(.systemGray6)
                    context.fill(Path(rect), with: .color(shade))
                }
            }
        }
    }
}

private extension UIColor {
    func isClose(to other: UIColor) -> Bool {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return abs(r1 - r2) < 0.04 && abs(g1 - g2) < 0.04 && abs(b1 - b2) < 0.04
    }
}
