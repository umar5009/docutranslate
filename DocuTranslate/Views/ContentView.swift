import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var reviewPrompt = ReviewPromptService.shared

    var body: some View {
        TabView(selection: $appState.currentTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(AppState.Tab.home)

            ScanView()
                .tabItem {
                    Label("Scan", systemImage: "camera.viewfinder")
                }
                .tag(AppState.Tab.scan)

            ConvertView()
                .tabItem {
                    Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(AppState.Tab.convert)

            TranslateView()
                .tabItem {
                    Label("Translate", systemImage: "globe")
                }
                .tag(AppState.Tab.translate)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppState.Tab.history)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(AppState.Tab.settings)
        }
        .accentColor(.blue)
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
            AppAnalytics.screen(appState.currentTab.rawValue)
        }
        .onChange(of: appState.currentTab) { tab in
            AppAnalytics.screen(tab.rawValue)
            AppAnalytics.tap("tab_selected", ["tab": tab.rawValue])
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHistoryTab)) { _ in
            appState.currentTab = .history
        }
        .alert("Enjoying DocuTranslate?", isPresented: $reviewPrompt.showAlert) {
            Button("Rate App") {
                AppAnalytics.tap("review_rate_app")
                reviewPrompt.rateNow()
            }
            Button("Not Now", role: .cancel) {
                AppAnalytics.tap("review_not_now")
                reviewPrompt.dismiss()
            }
        } message: {
            Text("If signing, stamping, and processing documents is working well, a quick App Store review would help others find the app.")
        }
    }
}
