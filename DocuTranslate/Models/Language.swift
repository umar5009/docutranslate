import Foundation

struct Language: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let nativeName: String
    let flag: String
    let code: String         // ISO 639-1
    let translationCode: String  // Used by translation APIs

    static func == (lhs: Language, rhs: Language) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - All Supported Languages
    static let all: [Language] = [
        Language(id: "en",  name: "English",             nativeName: "English",              flag: "🇬🇧", code: "en", translationCode: "en"),
        Language(id: "pl",  name: "Polish",               nativeName: "Polski",               flag: "🇵🇱", code: "pl", translationCode: "pl"),
        Language(id: "cs",  name: "Czech",                nativeName: "Čeština",              flag: "🇨🇿", code: "cs", translationCode: "cs"),
        Language(id: "sv",  name: "Swedish",              nativeName: "Svenska",              flag: "🇸🇪", code: "sv", translationCode: "sv"),
        Language(id: "de",  name: "German",               nativeName: "Deutsch",              flag: "🇩🇪", code: "de", translationCode: "de"),
        Language(id: "fr",  name: "French",               nativeName: "Français",             flag: "🇫🇷", code: "fr", translationCode: "fr"),
        Language(id: "es",  name: "Spanish",              nativeName: "Español",              flag: "🇪🇸", code: "es", translationCode: "es"),
        Language(id: "it",  name: "Italian",              nativeName: "Italiano",             flag: "🇮🇹", code: "it", translationCode: "it"),
        Language(id: "pt",  name: "Portuguese",           nativeName: "Português",            flag: "🇵🇹", code: "pt", translationCode: "pt"),
        Language(id: "ru",  name: "Russian",              nativeName: "Русский",              flag: "🇷🇺", code: "ru", translationCode: "ru"),
        Language(id: "zh",  name: "Chinese (Simplified)", nativeName: "简体中文",              flag: "🇨🇳", code: "zh", translationCode: "zh-Hans"),
        Language(id: "zh-TW", name: "Chinese (Traditional)", nativeName: "繁體中文",          flag: "🇹🇼", code: "zh-TW", translationCode: "zh-Hant"),
        Language(id: "ja",  name: "Japanese",             nativeName: "日本語",               flag: "🇯🇵", code: "ja", translationCode: "ja"),
        Language(id: "ko",  name: "Korean",               nativeName: "한국어",               flag: "🇰🇷", code: "ko", translationCode: "ko"),
        Language(id: "ar",  name: "Arabic",               nativeName: "العربية",              flag: "🇸🇦", code: "ar", translationCode: "ar"),
        Language(id: "hi",  name: "Hindi",                nativeName: "हिंदी",                flag: "🇮🇳", code: "hi", translationCode: "hi"),
        Language(id: "nl",  name: "Dutch",                nativeName: "Nederlands",           flag: "🇳🇱", code: "nl", translationCode: "nl"),
        Language(id: "tr",  name: "Turkish",              nativeName: "Türkçe",               flag: "🇹🇷", code: "tr", translationCode: "tr"),
        Language(id: "uk",  name: "Ukrainian",            nativeName: "Українська",           flag: "🇺🇦", code: "uk", translationCode: "uk"),
        Language(id: "ro",  name: "Romanian",             nativeName: "Română",               flag: "🇷🇴", code: "ro", translationCode: "ro"),
        Language(id: "hu",  name: "Hungarian",            nativeName: "Magyar",               flag: "🇭🇺", code: "hu", translationCode: "hu"),
        Language(id: "sk",  name: "Slovak",               nativeName: "Slovenčina",           flag: "🇸🇰", code: "sk", translationCode: "sk"),
        Language(id: "bg",  name: "Bulgarian",            nativeName: "Български",            flag: "🇧🇬", code: "bg", translationCode: "bg"),
        Language(id: "hr",  name: "Croatian",             nativeName: "Hrvatski",             flag: "🇭🇷", code: "hr", translationCode: "hr"),
        Language(id: "sr",  name: "Serbian",              nativeName: "Српски",               flag: "🇷🇸", code: "sr", translationCode: "sr"),
        Language(id: "da",  name: "Danish",               nativeName: "Dansk",                flag: "🇩🇰", code: "da", translationCode: "da"),
        Language(id: "fi",  name: "Finnish",              nativeName: "Suomi",                flag: "🇫🇮", code: "fi", translationCode: "fi"),
        Language(id: "nb",  name: "Norwegian",            nativeName: "Norsk",                flag: "🇳🇴", code: "nb", translationCode: "nb"),
        Language(id: "el",  name: "Greek",                nativeName: "Ελληνικά",             flag: "🇬🇷", code: "el", translationCode: "el"),
        Language(id: "he",  name: "Hebrew",               nativeName: "עברית",                flag: "🇮🇱", code: "he", translationCode: "he"),
        Language(id: "th",  name: "Thai",                 nativeName: "ภาษาไทย",              flag: "🇹🇭", code: "th", translationCode: "th"),
        Language(id: "vi",  name: "Vietnamese",           nativeName: "Tiếng Việt",           flag: "🇻🇳", code: "vi", translationCode: "vi"),
        Language(id: "id",  name: "Indonesian",           nativeName: "Bahasa Indonesia",     flag: "🇮🇩", code: "id", translationCode: "id"),
        Language(id: "ms",  name: "Malay",                nativeName: "Bahasa Melayu",        flag: "🇲🇾", code: "ms", translationCode: "ms"),
        Language(id: "fa",  name: "Persian",              nativeName: "فارسی",                flag: "🇮🇷", code: "fa", translationCode: "fa"),
        Language(id: "ur",  name: "Urdu",                 nativeName: "اردو",                 flag: "🇵🇰", code: "ur", translationCode: "ur"),
        Language(id: "bn",  name: "Bengali",              nativeName: "বাংলা",               flag: "🇧🇩", code: "bn", translationCode: "bn"),
        Language(id: "ca",  name: "Catalan",              nativeName: "Català",               flag: "🏴", code: "ca", translationCode: "ca"),
        Language(id: "lt",  name: "Lithuanian",           nativeName: "Lietuvių",             flag: "🇱🇹", code: "lt", translationCode: "lt"),
        Language(id: "lv",  name: "Latvian",              nativeName: "Latviešu",             flag: "🇱🇻", code: "lv", translationCode: "lv"),
        Language(id: "et",  name: "Estonian",             nativeName: "Eesti",                flag: "🇪🇪", code: "et", translationCode: "et"),
        Language(id: "sl",  name: "Slovenian",            nativeName: "Slovenščina",          flag: "🇸🇮", code: "sl", translationCode: "sl"),
        Language(id: "mk",  name: "Macedonian",           nativeName: "Македонски",           flag: "🇲🇰", code: "mk", translationCode: "mk"),
        Language(id: "sq",  name: "Albanian",             nativeName: "Shqip",                flag: "🇦🇱", code: "sq", translationCode: "sq"),
        Language(id: "af",  name: "Afrikaans",            nativeName: "Afrikaans",            flag: "🇿🇦", code: "af", translationCode: "af"),
        Language(id: "sw",  name: "Swahili",              nativeName: "Kiswahili",            flag: "🇰🇪", code: "sw", translationCode: "sw"),
        Language(id: "tl",  name: "Filipino",             nativeName: "Filipino",             flag: "🇵🇭", code: "tl", translationCode: "tl"),
        Language(id: "mn",  name: "Mongolian",            nativeName: "Монгол",               flag: "🇲🇳", code: "mn", translationCode: "mn"),
        Language(id: "ka",  name: "Georgian",             nativeName: "ქართული",              flag: "🇬🇪", code: "ka", translationCode: "ka"),
        Language(id: "hy",  name: "Armenian",             nativeName: "Հայերեն",              flag: "🇦🇲", code: "hy", translationCode: "hy"),
        Language(id: "az",  name: "Azerbaijani",          nativeName: "Azərbaycan",           flag: "🇦🇿", code: "az", translationCode: "az"),
        Language(id: "kk",  name: "Kazakh",               nativeName: "Қазақша",              flag: "🇰🇿", code: "kk", translationCode: "kk"),
        Language(id: "uz",  name: "Uzbek",                nativeName: "Oʻzbek",               flag: "🇺🇿", code: "uz", translationCode: "uz"),
        Language(id: "be",  name: "Belarusian",           nativeName: "Беларуская",           flag: "🇧🇾", code: "be", translationCode: "be"),
        Language(id: "mt",  name: "Maltese",              nativeName: "Malti",                flag: "🇲🇹", code: "mt", translationCode: "mt"),
        Language(id: "ga",  name: "Irish",                nativeName: "Gaeilge",              flag: "🇮🇪", code: "ga", translationCode: "ga"),
        Language(id: "cy",  name: "Welsh",                nativeName: "Cymraeg",              flag: "🏴󠁧󠁢󠁷󠁬󠁳󠁿", code: "cy", translationCode: "cy"),
        Language(id: "eu",  name: "Basque",               nativeName: "Euskara",              flag: "🏴", code: "eu", translationCode: "eu"),
        Language(id: "gl",  name: "Galician",             nativeName: "Galego",               flag: "🏴", code: "gl", translationCode: "gl"),
        Language(id: "la",  name: "Latin",                nativeName: "Latina",               flag: "🏛️", code: "la", translationCode: "la"),
    ]

    static let popular: [Language] = [
        all.first(where: { $0.id == "en" })!,
        all.first(where: { $0.id == "pl" })!,
        all.first(where: { $0.id == "cs" })!,
        all.first(where: { $0.id == "sv" })!,
        all.first(where: { $0.id == "de" })!,
        all.first(where: { $0.id == "fr" })!,
        all.first(where: { $0.id == "es" })!,
        all.first(where: { $0.id == "it" })!,
        all.first(where: { $0.id == "pt" })!,
        all.first(where: { $0.id == "ar" })!,
        all.first(where: { $0.id == "zh" })!,
        all.first(where: { $0.id == "ja" })!,
        all.first(where: { $0.id == "ko" })!,
        all.first(where: { $0.id == "ru" })!,
        all.first(where: { $0.id == "hi" })!,
    ]

    static var english: Language {
        all.first(where: { $0.id == "en" })!
    }

    /// Device language when it is not English, otherwise Spanish so EN→EN is not the default.
    static var preferredTarget: Language {
        let code = Locale.current.language.languageCode?.identifier
            ?? Locale.current.identifier.split(separator: "-").first.map(String.init)
            ?? "en"
        if let match = find(by: code), match.id != "en" {
            return match
        }
        return find(by: "es") ?? find(by: "pl") ?? all[1]
    }

    /// Language code used by Google / Lingva / MyMemory.
    var googleCode: String {
        switch id {
        case "zh": return "zh-CN"
        case "zh-TW": return "zh-TW"
        case "nb": return "no"
        default: return code
        }
    }

    static func find(by code: String) -> Language? {
        if let match = all.first(where: { $0.code == code || $0.translationCode == code || $0.id == code }) {
            return match
        }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return all.first(where: { $0.code == base || $0.translationCode.hasPrefix(base) })
    }
}
