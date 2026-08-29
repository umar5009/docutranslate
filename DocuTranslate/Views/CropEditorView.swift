import SwiftUI

struct CropEditorView: View {
    @ObservedObject var vm: ScanViewModel
    let pageIndex: Int
    @Environment(\.dismiss) private var dismiss

    @State private var topLeft     = CGPoint(x: 0.08, y: 0.08)
    @State private var topRight    = CGPoint(x: 0.92, y: 0.08)
    @State private var bottomRight = CGPoint(x: 0.92, y: 0.92)
    @State private var bottomLeft  = CGPoint(x: 0.08, y: 0.92)

    @State private var imageSize: CGSize = .zero
    private let handleSize: CGFloat = 26

    var image: UIImage {
        vm.session.pages[pageIndex].displayImage
    }

    var body: some View {
        NavigationView {
            GeometryReader { geo in
                ZStack {
                    // Dark background
                    Color.black.ignoresSafeArea()

                    // Image
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(
                            GeometryReader { imgGeo in
                                cropOverlay(in: imgGeo.size)
                                    .onAppear { imageSize = imgGeo.size }
                            }
                        )
                }
            }
            .navigationTitle("Crop & Align")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: AppAnalytics.action("crop_cancel") { dismiss() })
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply", action: AppAnalytics.action("crop_apply") { applyCrop() })
                        .font(.headline)
                        .foregroundColor(.yellow)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Reset", action: AppAnalytics.action("crop_reset") { resetHandles() })
                        .foregroundColor(.white)
                    Spacer()
                    Button("Auto-detect") {
                        AppAnalytics.tap("crop_auto_detect")
                        Task { await autoDetect() }
                    }
                    .foregroundColor(.blue)
                    Spacer()
                    Button("Rotate") {
                        AppAnalytics.tap("crop_rotate")
                        vm.rotatePage(at: pageIndex)
                    }
                    .foregroundColor(.white)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Crop Overlay

    private func cropOverlay(in size: CGSize) -> some View {
        ZStack {
            // Semi-transparent mask outside crop area
            CropMaskShape(
                tl: point(topLeft, in: size),
                tr: point(topRight, in: size),
                br: point(bottomRight, in: size),
                bl: point(bottomLeft, in: size),
                size: size
            )
            .fill(Color.black.opacity(0.5))

            // Crop border
            Path { path in
                let tl = point(topLeft, in: size)
                let tr = point(topRight, in: size)
                let br = point(bottomRight, in: size)
                let bl = point(bottomLeft, in: size)
                path.move(to: tl)
                path.addLine(to: tr)
                path.addLine(to: br)
                path.addLine(to: bl)
                path.closeSubpath()
            }
            .stroke(Color.yellow, lineWidth: 2)

            // Grid lines inside crop
            cropGridLines(in: size)

            // Corner handles
            cornerHandle(pos: $topLeft, in: size, corner: .topLeft)
            cornerHandle(pos: $topRight, in: size, corner: .topRight)
            cornerHandle(pos: $bottomRight, in: size, corner: .bottomRight)
            cornerHandle(pos: $bottomLeft, in: size, corner: .bottomLeft)
        }
    }

    private func cropGridLines(in size: CGSize) -> some View {
        let tl = point(topLeft, in: size)
        let tr = point(topRight, in: size)
        let br = point(bottomRight, in: size)
        let bl = point(bottomLeft, in: size)

        return Path { path in
            // Horizontal thirds
            for t in [1.0/3, 2.0/3] {
                let left  = CGPoint(x: tl.x + (bl.x - tl.x) * t, y: tl.y + (bl.y - tl.y) * t)
                let right = CGPoint(x: tr.x + (br.x - tr.x) * t, y: tr.y + (br.y - tr.y) * t)
                path.move(to: left); path.addLine(to: right)
            }
            // Vertical thirds
            for t in [1.0/3, 2.0/3] {
                let top = CGPoint(x: tl.x + (tr.x - tl.x) * t, y: tl.y + (tr.y - tl.y) * t)
                let bot = CGPoint(x: bl.x + (br.x - bl.x) * t, y: bl.y + (br.y - bl.y) * t)
                path.move(to: top); path.addLine(to: bot)
            }
        }
        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
    }

    private func cornerHandle(pos: Binding<CGPoint>, in size: CGSize, corner: Corner) -> some View {
        let p = point(pos.wrappedValue, in: size)
        return ZStack {
            Circle()
                .fill(Color.yellow)
                .frame(width: handleSize, height: handleSize)
            cornerLines(for: corner)
                .stroke(Color.black, lineWidth: 2)
                .frame(width: handleSize * 0.6, height: handleSize * 0.6)
        }
        .position(p)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in
                    let newX = (val.location.x / size.width).clamped(to: 0...1)
                    let newY = (val.location.y / size.height).clamped(to: 0...1)
                    pos.wrappedValue = CGPoint(x: newX, y: newY)
                }
        )
    }

    enum Corner { case topLeft, topRight, bottomRight, bottomLeft }

    private func cornerLines(for corner: Corner) -> Path {
        Path { path in
            let s: CGFloat = 8
            switch corner {
            case .topLeft:
                path.move(to: CGPoint(x: s, y: 0)); path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: s))
            case .topRight:
                path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: s, y: 0))
                path.addLine(to: CGPoint(x: s, y: s))
            case .bottomRight:
                path.move(to: CGPoint(x: s, y: 0)); path.addLine(to: CGPoint(x: s, y: s))
                path.addLine(to: CGPoint(x: 0, y: s))
            case .bottomLeft:
                path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: 0, y: s))
                path.addLine(to: CGPoint(x: s, y: s))
            }
        }
    }

    // MARK: - Helpers

    private func point(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func resetHandles() {
        withAnimation {
            topLeft     = CGPoint(x: 0.08, y: 0.08)
            topRight    = CGPoint(x: 0.92, y: 0.08)
            bottomRight = CGPoint(x: 0.92, y: 0.92)
            bottomLeft  = CGPoint(x: 0.08, y: 0.92)
        }
    }

    private func autoDetect() async {
        let img = vm.session.pages[pageIndex].originalImage
        if let corners = await ScannerService.shared.detectDocumentBounds(in: img) {
            let w = img.size.width, h = img.size.height
            withAnimation {
                topLeft     = CGPoint(x: corners[0].x / w, y: corners[0].y / h)
                topRight    = CGPoint(x: corners[1].x / w, y: corners[1].y / h)
                bottomRight = CGPoint(x: corners[2].x / w, y: corners[2].y / h)
                bottomLeft  = CGPoint(x: corners[3].x / w, y: corners[3].y / h)
            }
        }
    }

    private func applyCrop() {
        let imgSize = image.size
        let minX = min(topLeft.x, bottomLeft.x) * imgSize.width
        let minY = min(topLeft.y, topRight.y) * imgSize.height
        let maxX = max(topRight.x, bottomRight.x) * imgSize.width
        let maxY = max(bottomLeft.y, bottomRight.y) * imgSize.height
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        vm.cropPage(at: pageIndex, rect: rect)
        dismiss()
    }
}

// MARK: - Crop Mask Shape

struct CropMaskShape: Shape {
    let tl, tr, br, bl: CGPoint
    let size: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Full rect
        path.addRect(rect)
        // Subtract crop area (using evenOdd fill)
        path.move(to: tl)
        path.addLine(to: tr)
        path.addLine(to: br)
        path.addLine(to: bl)
        path.closeSubpath()
        return path
    }
}

// MARK: - Extensions

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Stamp photo crop

struct StampCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onCrop: (UIImage) -> Void

    @State private var working: UIImage
    @State private var minX: CGFloat = 0.08
    @State private var minY: CGFloat = 0.08
    @State private var maxX: CGFloat = 0.92
    @State private var maxY: CGFloat = 0.92
    @State private var canvasSize: CGSize = .zero
    @State private var activeHandle: CropHandle?
    @State private var startMinX: CGFloat = 0
    @State private var startMinY: CGFloat = 0
    @State private var startMaxX: CGFloat = 1
    @State private var startMaxY: CGFloat = 1

    private let handleSize: CGFloat = 28
    private let minNormalized: CGFloat = 0.12

    init(image: UIImage, onCancel: @escaping () -> Void, onCrop: @escaping (UIImage) -> Void) {
        self.image = image
        self.onCancel = onCancel
        self.onCrop = onCrop
        _working = State(initialValue: image)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: working)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        GeometryReader { geo in
                            cropLayer(in: geo.size)
                                .onAppear { canvasSize = geo.size }
                                .onChange(of: geo.size) { canvasSize = $0 }
                        }
                    )
            }
            .navigationTitle("Crop Stamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: AppAnalytics.action("stamp_crop_cancel") { onCancel() })
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Use Crop", action: AppAnalytics.action("stamp_crop_use") { apply() })
                        .font(.headline)
                        .foregroundColor(.yellow)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Reset", action: AppAnalytics.action("stamp_crop_reset") { resetCrop() })
                        .foregroundColor(.white)
                    Spacer()
                    Button("Rotate", action: AppAnalytics.action("stamp_crop_rotate") { rotate() })
                        .foregroundColor(.white)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func cropLayer(in size: CGSize) -> some View {
        let tl = CGPoint(x: minX * size.width, y: minY * size.height)
        let tr = CGPoint(x: maxX * size.width, y: minY * size.height)
        let br = CGPoint(x: maxX * size.width, y: maxY * size.height)
        let bl = CGPoint(x: minX * size.width, y: maxY * size.height)
        let cropRect = CGRect(x: tl.x, y: tl.y, width: tr.x - tl.x, height: bl.y - tl.y)

        return ZStack {
            CropMaskShape(tl: tl, tr: tr, br: br, bl: bl, size: size)
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(bodyDrag(in: size))

            handle(at: tl, type: .topLeft, in: size)
            handle(at: tr, type: .topRight, in: size)
            handle(at: br, type: .bottomRight, in: size)
            handle(at: bl, type: .bottomLeft, in: size)
        }
    }

    private func handle(at point: CGPoint, type: CropHandle, in size: CGSize) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: handleSize, height: handleSize)
            .shadow(radius: 2)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if activeHandle == nil {
                            activeHandle = type
                            rememberStart()
                        }
                        updateHandle(type, translation: value.translation, in: size)
                    }
                    .onEnded { _ in activeHandle = nil }
            )
    }

    private func bodyDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if activeHandle == nil {
                    activeHandle = .body
                    rememberStart()
                }
                guard activeHandle == .body else { return }
                let dx = value.translation.width / max(size.width, 1)
                let dy = value.translation.height / max(size.height, 1)
                let width = startMaxX - startMinX
                let height = startMaxY - startMinY
                var nextMinX = (startMinX + dx).clamped(to: 0...1)
                var nextMinY = (startMinY + dy).clamped(to: 0...1)
                var nextMaxX = nextMinX + width
                var nextMaxY = nextMinY + height
                if nextMaxX > 1 {
                    nextMaxX = 1
                    nextMinX = 1 - width
                }
                if nextMaxY > 1 {
                    nextMaxY = 1
                    nextMinY = 1 - height
                }
                minX = nextMinX
                minY = nextMinY
                maxX = nextMaxX
                maxY = nextMaxY
            }
            .onEnded { _ in activeHandle = nil }
    }

    private func rememberStart() {
        startMinX = minX
        startMinY = minY
        startMaxX = maxX
        startMaxY = maxY
    }

    private func updateHandle(_ handle: CropHandle, translation: CGSize, in size: CGSize) {
        let dx = translation.width / max(size.width, 1)
        let dy = translation.height / max(size.height, 1)
        switch handle {
        case .topLeft:
            minX = (startMinX + dx).clamped(to: 0...(maxX - minNormalized))
            minY = (startMinY + dy).clamped(to: 0...(maxY - minNormalized))
        case .topRight:
            maxX = (startMaxX + dx).clamped(to: (minX + minNormalized)...1)
            minY = (startMinY + dy).clamped(to: 0...(maxY - minNormalized))
        case .bottomRight:
            maxX = (startMaxX + dx).clamped(to: (minX + minNormalized)...1)
            maxY = (startMaxY + dy).clamped(to: (minY + minNormalized)...1)
        case .bottomLeft:
            minX = (startMinX + dx).clamped(to: 0...(maxX - minNormalized))
            maxY = (startMaxY + dy).clamped(to: (minY + minNormalized)...1)
        case .body:
            break
        }
    }

    private func resetCrop() {
        withAnimation {
            minX = 0.08; minY = 0.08; maxX = 0.92; maxY = 0.92
        }
    }

    private func rotate() {
        working = ScannerService.shared.rotate(image: working, degrees: 90)
        resetCrop()
    }

    private func apply() {
        let size = working.size
        let rect = CGRect(
            x: minX * size.width,
            y: minY * size.height,
            width: (maxX - minX) * size.width,
            height: (maxY - minY) * size.height
        ).integral
        guard rect.width > 2, rect.height > 2 else {
            onCrop(working)
            return
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = working.scale
        format.opaque = false
        let cropped = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            working.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
        AppAnalytics.log("stamp_cropped")
        onCrop(cropped)
    }

    private enum CropHandle {
        case topLeft, topRight, bottomRight, bottomLeft, body
    }
}
