import SwiftUI
import Speech
import AVFoundation

struct StampChatView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var speech = StampSpeechRecognizer()
    @State private var messages: [StampChatMessage] = [
        StampChatMessage(
            role: .assistant,
            text: "Describe the stamp you want. Try: “Create a blue company seal for Acme Corp with today’s date.” You can type or use the microphone."
        )
    ]
    @State private var draft = ""
    @State private var isGenerating = false
    @State private var blueprint: StampBlueprint?
    @State private var stampImage: UIImage?
    @State private var shouldSave = true
    @State private var errorMessage: String?

    let onComplete: (UIImage?) -> Void
    private let prompts = StampPromptService.shared
    private let stamps = SignStampService.shared

    private let suggestions = [
        "Blue company seal for Acme Corp with today’s date",
        "Red CANCELLED stamp",
        "Green APPROVED circle",
        "Purple confidential stamp with date"
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(messages) { message in
                                chatBubble(message)
                                    .id(message.id)
                            }

                            if let stampImage {
                                stampPreview(stampImage)
                                    .id("preview")
                            }

                            if isGenerating {
                                HStack {
                                    ProgressView()
                                    Text("Designing your stamp…")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .id("busy")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }

                if stampImage == nil && !isGenerating {
                    suggestionRow
                }

                inputBar
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("AI Stamp Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: AppAnalytics.action("stamp_chat_cancel") { dismiss() })
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Use Stamp", action: AppAnalytics.action("stamp_chat_use") { finish() })
                        .font(.headline)
                        .disabled(stampImage == nil)
                }
            }
            .alert("Speech", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel, action: AppAnalytics.action("stamp_chat_error_ok") { errorMessage = nil })
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: speech.transcript) { value in
                if speech.isRecording {
                    draft = value
                }
            }
        }
    }

    private func chatBubble(_ message: StampChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(.subheadline)
                .padding(12)
                .background(message.role == .user ? Color.purple.opacity(0.18) : Color(.systemBackground))
                .cornerRadius(14)
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private func stampPreview(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                CheckerboardBackground()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(.systemGray4)))

            Toggle("Save stamp for future use", isOn: $shouldSave)
                .font(.subheadline)
        }
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { item in
                    Button(item) {
                        AppAnalytics.tap("stamp_chat_suggestion")
                        draft = item
                        send()
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.purple.opacity(0.12))
                    .foregroundColor(.purple)
                    .cornerRadius(16)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if speech.isRecording {
                Text("Listening… tap the mic to stop")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack(spacing: 10) {
                TextField("Type a stamp prompt", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(speech.isRecording)

                Button {
                    AppAnalytics.tap(speech.isRecording ? "stamp_chat_mic_stop" : "stamp_chat_mic")
                    toggleSpeech()
                } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundColor(speech.isRecording ? .red : .purple)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(speech.isRecording ? "Stop recording" : "Voice prompt")

                Button {
                    AppAnalytics.tap("stamp_chat_send")
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundColor(canSend ? .purple : .gray)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    private func toggleSpeech() {
        if speech.isRecording {
            speech.stop()
            if !speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = speech.transcript
                send()
            }
        } else {
            Task {
                do {
                    try await speech.start()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(StampChatMessage(role: .user, text: text))
        draft = ""
        speech.reset()
        isGenerating = true

        Task {
            let result = await prompts.generate(from: text, previous: blueprint)
            await MainActor.run {
                blueprint = result.blueprint
                stampImage = result.image
                messages.append(StampChatMessage(role: .assistant, text: result.reply))
                isGenerating = false
                AppAnalytics.log("stamp_ai_created", ["color": result.blueprint.colorName])
            }
        }
    }

    private func finish() {
        guard let stampImage else { return }
        if shouldSave {
            stamps.saveStamp(stampImage, name: blueprint?.displayName ?? "AI Stamp")
        }
        onComplete(stampImage)
        dismiss()
    }
}

private struct StampChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

@MainActor
final class StampSpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func reset() {
        transcript = ""
    }

    func start() async throws {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speech == .authorized else {
            throw StampSpeechError.notAuthorized
        }

        let micGranted = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        guard micGranted else { throw StampSpeechError.notAuthorized }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request, let recognizer, recognizer.isAvailable else {
            throw StampSpeechError.unavailable
        }
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        transcript = ""

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    self.transcript = result.bestTranscription.formattedString
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private enum StampSpeechError: LocalizedError {
    case notAuthorized, unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Enable Speech Recognition and Microphone access in Settings to dictate stamp prompts."
        case .unavailable:
            return "Speech recognition is not available on this device."
        }
    }
}
