import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    func name(of option: AppLanguage) -> String {
        switch option {
        case .system: text("language.system")
        case .english: "English"
        case .chinese: "简体中文"
        case .japanese: "日本語"
        }
    }

    var locale: Locale { Locale(identifier: resolved.rawValue) }

    private var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Bundle.preferredLocalizations(
            from: [Self.english.rawValue, Self.chinese.rawValue, Self.japanese.rawValue],
            forPreferences: Locale.preferredLanguages
        )
        return preferred.first.flatMap(Self.init(rawValue:)) ?? .english
    }

    func text(_ key: String, _ arguments: String...) -> String {
        resolve(InterfaceMessage(key, arguments: arguments))
    }

    func resolve(_ message: InterfaceMessage) -> String {
        let format = Self.bundles[resolved]?.localizedString(forKey: message.key, value: nil, table: nil) ?? message.key
        guard !message.arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: message.arguments)
    }

    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        [Self.english, .chinese, .japanese].compactMap { language in
            let url = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj")
                ?? Bundle.module.url(forResource: language.rawValue, withExtension: "lproj")
            guard let url, let bundle = Bundle(url: url) else { return nil }
            return (language, bundle)
        }
    )
}

struct InterfaceMessage: Equatable, ExpressibleByStringLiteral {
    let key: String
    let arguments: [String]

    init(_ key: String, arguments: [String]) {
        self.key = key
        self.arguments = arguments
    }

    init(stringLiteral value: String) {
        self.init(value, arguments: [])
    }
}
