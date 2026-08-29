import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage("defaultSourceLanguage") private var defaultSourceCode = "en"
    @AppStorage("defaultTargetLanguage") private var defaultTargetCode = "pl"
    @AppStorage("scanQuality") private var scanQuality = "High"
    @AppStorage("autoDetectLanguage") private var autoDetect = true
    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("hapticFeedback") private var hapticFeedback = true

    @State private var showSourcePicker = false
    @State private var showTargetPicker = false
    @State private var sourceLanguage = Language.all.first(where: { $0.code == "en" })!
    @State private var targetLanguage = Language.all.first(where: { $0.code == "pl" })!
    @State private var showAbout = false
    @ObservedObject private var push = PushNotificationService.shared

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { push.isAuthorized },
            set: { enabled in
                AppAnalytics.tap("settings_notifications", ["on": enabled])
                PushNotificationService.shared.setEnabled(enabled)
            }
        )
    }

    private var notificationsFooter: String {
        switch push.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "Alerts are on for this device"
        case .denied:
            return "Disabled in iOS Settings"
        default:
            return "Get alerts about your documents"
        }
    }

    var body: some View {
        NavigationView {
            List {
                // Default languages
                Section {
                    Button {
                        AppAnalytics.tap("settings_source_language")
                        showSourcePicker = true
                    } label: {
                        SettingsRow(
                            icon: "globe",
                            iconColor: .blue,
                            title: "Default Source",
                            value: "\(sourceLanguage.flag) \(sourceLanguage.name)"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        AppAnalytics.tap("settings_target_language")
                        showTargetPicker = true
                    } label: {
                        SettingsRow(
                            icon: "arrow.triangle.2.circlepath",
                            iconColor: .green,
                            title: "Default Target",
                            value: "\(targetLanguage.flag) \(targetLanguage.name)"
                        )
                    }
                    .buttonStyle(.plain)

                    Toggle(isOn: $autoDetect) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-detect Language")
                                Text("Detect source language automatically")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "sparkle")
                                .foregroundColor(.purple)
                        }
                    }
                    .onChange(of: autoDetect) { _, on in
                        AppAnalytics.tap("settings_auto_detect", ["on": on])
                    }
                } header: {
                    Text("Translation")
                }

                // Scan settings
                Section {
                    Picker(selection: $scanQuality) {
                        Text("Standard").tag("Standard")
                        Text("High").tag("High")
                        Text("Ultra").tag("Ultra")
                    } label: {
                        Label {
                            Text("Scan Quality")
                        } icon: {
                            Image(systemName: "camera.viewfinder")
                                .foregroundColor(.purple)
                        }
                    }
                } header: {
                    Text("Scanning")
                }
                .onChange(of: scanQuality) { _, value in
                    AppAnalytics.tap("settings_scan_quality", ["quality": value])
                }

                Section {
                    SavedSignaturesSettingsSection()
                } header: {
                    Text("Sign & Stamp")
                } footer: {
                    Text("Saved signatures and stamps can be reused from the Scan tab.")
                }

                Section {
                    SavedStampsSettingsSection()
                } header: {
                    Text("Saved Stamps")
                }

                Section {
                    ExportLocationSection()
                } header: {
                    Text("Export Location")
                } footer: {
                    Text("PDF, Word, TXT, and CSV files are saved to the Files app. JPEG and PNG images are saved to Photos — one image per page.")
                }

                // App settings
                Section {
                    Toggle(isOn: $saveHistory) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Save History")
                                Text("Keep translated, scanned, and signed documents in History")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.orange)
                        }
                    }
                    .onChange(of: saveHistory) { _, on in
                        AppAnalytics.tap("settings_save_history", ["on": on])
                    }

                    Toggle(isOn: $hapticFeedback) {
                        Label("Haptic Feedback", systemImage: "hand.tap.fill")
                            .foregroundColor(.primary)
                    }
                    .tint(.blue)
                    .onChange(of: hapticFeedback) { _, on in
                        AppAnalytics.tap("settings_haptics", ["on": on])
                    }
                } header: {
                    Text("App")
                }

                Section {
                    Toggle(isOn: notificationsBinding) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Push Notifications")
                                Text(notificationsFooter)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "bell.badge.fill")
                                .foregroundColor(.red)
                        }
                    }
                    .tint(.blue)

                    if push.authorizationStatus == .denied {
                        Button {
                            AppAnalytics.tap("settings_open_ios")
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            SettingsRow(icon: "gear", iconColor: .gray, title: "Open iOS Settings", value: "")
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("DocuTranslate can send document reminders and updates through Firebase Cloud Messaging.")
                }

                // Supported formats info
                Section {
                    ForEach(DocumentType.allCases, id: \.self) { type in
                        HStack(spacing: 12) {
                            Image(systemName: type.icon)
                                .foregroundColor(Color(hex: type.color))
                                .frame(width: 24)
                            Text(type.rawValue)
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 14))
                        }
                    }
                } header: {
                    Text("Supported Document Types")
                }

                // About
                Section {
                    Button {
                        AppAnalytics.tap("settings_about")
                        showAbout = true
                    } label: {
                        SettingsRow(icon: "info.circle", iconColor: .blue, title: "About DocuTranslate", value: "v1.0.0")
                    }
                    .buttonStyle(.plain)

                    Button {
                        AppAnalytics.tap("settings_rate_app")
                        ReviewPromptService.shared.requestStoreReview()
                    } label: {
                        SettingsRow(icon: "star.fill", iconColor: .orange, title: "Rate DocuTranslate", value: "")
                    }
                    .buttonStyle(.plain)

                    Link(destination: URL(string: "https://www.apple.com/legal/privacy/")!) {
                        SettingsRow(icon: "hand.raised.fill", iconColor: .gray, title: "Privacy Policy", value: "")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        AppAnalytics.tap("settings_privacy")
                    })
                } header: {
                    Text("About")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await push.refreshStatus()
            }
            .sheet(isPresented: $showSourcePicker) {
                LanguagePickerSheet(
                    title: "Default Source Language",
                    selection: $sourceLanguage,
                    showAutoDetect: false,
                    autoDetect: .constant(false)
                )
            }
            .sheet(isPresented: $showTargetPicker) {
                LanguagePickerSheet(
                    title: "Default Target Language",
                    selection: $targetLanguage,
                    showAutoDetect: false,
                    autoDetect: .constant(false)
                )
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
        }
    }
}

// MARK: - Settings Row

struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(iconColor)
                .cornerRadius(6)

            Text(title)
                .foregroundColor(.primary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 28) {
                    // App icon area
                    VStack(spacing: 12) {
                        ZStack {
                            LinearGradient(
                                colors: [Color(hex: "#1a56d6"), Color(hex: "#0f3a9e")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(width: 100, height: 100)
                            .cornerRadius(22)

                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 44, weight: .light))
                                .foregroundColor(.white)
                        }

                        Text("DocuTranslate")
                            .font(.title.bold())

                        Text("Version 1.0.0")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 32)

                    // Features
                    VStack(alignment: .leading, spacing: 14) {
                        AboutFeatureRow(icon: "globe", color: .blue, title: "60+ Languages", detail: "Translate into any major world language")
                        AboutFeatureRow(icon: "camera.viewfinder", color: .purple, title: "CamScanner-style", detail: "Scan, crop, align and filter documents")
                        AboutFeatureRow(icon: "signature", color: .red, title: "Sign & Stamp", detail: "Add signature and official stamp together")
                        AboutFeatureRow(icon: "doc.badge.plus", color: .green, title: "Any Document Type", detail: "PDF, Word, Excel, PowerPoint, images, text")
                        AboutFeatureRow(icon: "square.and.arrow.up", color: .orange, title: "Multiple Export Formats", detail: "Export as PDF, Word, JPEG, PNG, TXT, CSV")
                        AboutFeatureRow(icon: "text.viewfinder", color: .red, title: "Smart OCR", detail: "Extract text from scanned & image documents")
                        AboutFeatureRow(icon: "sparkle", color: .indigo, title: "Auto Language Detection", detail: "Automatically identifies source language")
                    }
                    .padding(.horizontal)

                    // Tech
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Powered By")
                            .font(.headline)
                            .padding(.horizontal)

                        VStack(spacing: 8) {
                            TechRow(name: "Apple Translation Framework", detail: "iOS 17.4+")
                            TechRow(name: "Vision Framework (OCR)", detail: "Apple")
                            TechRow(name: "VisionKit (Document Scan)", detail: "Apple")
                            TechRow(name: "CoreImage (Filters)", detail: "Apple")
                            TechRow(name: "PDFKit", detail: "Apple")
                            TechRow(name: "Firebase Analytics", detail: "Google")
                            TechRow(name: "Firebase Cloud Messaging", detail: "Push notifications")
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done", action: AppAnalytics.action("settings_about_done") { dismiss() })
                }
            }
        }
    }
}

struct AboutFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(color)
                .cornerRadius(9)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct TechRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack {
            Text(name)
                .font(.subheadline)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

struct ExportLocationSection: View {
    @State private var savedFiles: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Documents (PDF, Word, TXT…)")
                        .font(.subheadline.weight(.medium))
                    Text("Files → On My iPhone → DocuTranslate → Exports")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundColor(.blue)
            }

            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Images (JPEG, PNG)")
                        .font(.subheadline.weight(.medium))
                    Text("Photos app → Recents")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } icon: {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundColor(.pink)
            }

            if savedFiles.isEmpty {
                Text("No exported documents yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Recent exports")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                ForEach(savedFiles.prefix(5), id: \.path) { url in
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundColor(.blue)
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
        .onAppear {
            savedFiles = ExportService.shared.listSavedDocuments()
        }
    }
}

struct SavedSignaturesSettingsSection: View {
    @State private var savedSignatures: [SavedSignature] = []

    var body: some View {
        Group {
            if savedSignatures.isEmpty {
                Text("No saved signatures yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(savedSignatures) { saved in
                    HStack(spacing: 12) {
                        if let image = saved.image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 80, height: 36)
                                .padding(6)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(saved.name)
                                .font(.subheadline.weight(.medium))
                            Text(saved.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            AppAnalytics.tap("settings_delete_signature")
                            SignStampService.shared.deleteSavedSignature(id: saved.id)
                            savedSignatures = SignStampService.shared.loadSavedSignatures()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .onAppear {
            savedSignatures = SignStampService.shared.loadSavedSignatures()
        }
    }
}

struct SavedStampsSettingsSection: View {
    @State private var savedStamps: [SavedStamp] = []

    var body: some View {
        Group {
            if savedStamps.isEmpty {
                Text("No saved stamps yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(savedStamps) { saved in
                    HStack(spacing: 12) {
                        if let image = saved.image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .padding(6)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(saved.name)
                                .font(.subheadline.weight(.medium))
                            Text(saved.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            AppAnalytics.tap("settings_delete_stamp")
                            SignStampService.shared.deleteSavedStamp(id: saved.id)
                            savedStamps = SignStampService.shared.loadSavedStamps()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .onAppear {
            savedStamps = SignStampService.shared.loadSavedStamps()
        }
    }
}
