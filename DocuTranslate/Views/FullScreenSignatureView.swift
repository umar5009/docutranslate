import SwiftUI
import PencilKit

struct FullScreenSignatureView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var canvasView = PKCanvasView()
    @State private var inkColor: Color = .black
    @State private var shouldSave = false

    let onComplete: (UIImage?) -> Void

    private let service = SignStampService.shared

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 16) {
                    Text("Sign in the area below using your finger or Apple Pencil")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    ZStack(alignment: .topTrailing) {
                        SignatureCanvasView(canvasView: $canvasView, inkColor: UIColor(inkColor))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Color(.systemGray3), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)

                        Button {
                            AppAnalytics.tap("signature_clear")
                            canvasView.drawing = PKDrawing()
                        } label: {
                            Label("Clear", systemImage: "arrow.counterclockwise")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        .padding(12)
                    }
                    .padding(.horizontal)
                    .frame(maxHeight: .infinity)

                    HStack(spacing: 16) {
                        Text("Ink color")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        ForEach([Color.black, Color.blue, Color(red: 0.1, green: 0.2, blue: 0.6)], id: \.self) { color in
                            Circle()
                                .fill(color)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Circle().strokeBorder(inkColor == color ? Color.blue : Color.clear, lineWidth: 3)
                                )
                                .onTapGesture {
                                    AppAnalytics.tap("signature_ink")
                                    inkColor = color
                                }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 24)

                    Toggle(isOn: $shouldSave) {
                        Text("Save signature for future use")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
                .padding(.top, 8)
            }
            .navigationTitle("Draw Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: AppAnalytics.action("signature_cancel") { dismiss() })
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Use Signature", action: AppAnalytics.action("signature_use") { finish() })
                        .font(.headline)
                        .disabled(canvasView.drawing.strokes.isEmpty)
                }
            }
            .onAppear { configureCanvas() }
            .onChange(of: inkColor) { _ in configureCanvas() }
        }
    }

    private func configureCanvas() {
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: UIColor(inkColor), width: 4)
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true
    }

    private func finish() {
        guard let image = service.signatureFromCanvas(canvasView) else { return }
        if shouldSave { service.saveSignature(image) }
        onComplete(image)
        dismiss()
    }
}
