import Foundation

#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif

enum AppAnalytics {
    static let eventPrefix = "docutranslate_"
    static var isConfigured = false

    static func configure() {
        guard !isConfigured else { return }
        guard hasValidFirebasePlist() else {
            #if DEBUG
            print("Firebase Analytics is not active. Replace DocuTranslate/Resources/GoogleService-Info.plist with the file from your Firebase Console.")
            #endif
            return
        }
        #if canImport(FirebaseCore)
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        #endif
        #if canImport(FirebaseAnalytics)
        Analytics.setAnalyticsCollectionEnabled(true)
        #endif
        isConfigured = true
        log("app_open")
    }

    /// Logs a button tap. Event names are sent as `docutranslate_<name>`.
    static func tap(_ name: String, _ parameters: [String: Any] = [:]) {
        var params = parameters
        params["interaction"] = "tap"
        log(name, params)
    }

    /// Wrap a button action so the tap is always logged.
    static func action(_ name: String, _ parameters: [String: Any] = [:], _ work: @escaping () -> Void) -> () -> Void {
        {
            tap(name, parameters)
            work()
        }
    }

    static func log(_ name: String, _ parameters: [String: Any] = [:]) {
        let event = firebaseEventName(name)
        #if DEBUG
        print("[Analytics] \(event) \(parameters)")
        #endif
        guard isConfigured else { return }
        #if canImport(FirebaseAnalytics)
        Analytics.logEvent(event, parameters: parameters.isEmpty ? nil : sanitized(parameters))
        #endif
    }

    static func screen(_ name: String) {
        log("screen_view", ["screen_name": name])
        guard isConfigured else { return }
        #if canImport(FirebaseAnalytics)
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: name,
            AnalyticsParameterScreenClass: name
        ])
        #endif
    }

    static func setUserProperty(_ value: String?, forName name: String) {
        guard isConfigured else { return }
        #if canImport(FirebaseAnalytics)
        Analytics.setUserProperty(value, forName: name)
        #endif
    }

    /// Firebase event names: letter first, [a-z0-9_], max 40 chars.
    static func firebaseEventName(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix(eventPrefix) {
            key = String(key.dropFirst(eventPrefix.count))
        }
        key = key
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        key = String(key.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        while key.contains("__") {
            key = key.replacingOccurrences(of: "__", with: "_")
        }
        key = key.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if key.first?.isNumber == true {
            key = "e_" + key
        }
        if key.isEmpty { key = "event" }
        let maxTail = 40 - eventPrefix.count
        return eventPrefix + String(key.prefix(maxTail))
    }

    private static func sanitized(_ parameters: [String: Any]) -> [String: Any] {
        parameters.reduce(into: [String: Any]()) { result, item in
            let key = String(item.key.prefix(40))
            switch item.value {
            case let value as String:
                result[key] = String(value.prefix(100))
            case let value as Int:
                result[key] = value
            case let value as Double:
                result[key] = value
            case let value as Bool:
                result[key] = value ? "true" : "false"
            default:
                result[key] = String(String(describing: item.value).prefix(100))
            }
        }
    }

    static func hasValidFirebasePlist() -> Bool {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let appID = dict["GOOGLE_APP_ID"] as? String else {
            return false
        }
        return appID.contains(":ios:")
            && !appID.contains("YOUR_")
            && !appID.contains("000000000000")
    }
}
