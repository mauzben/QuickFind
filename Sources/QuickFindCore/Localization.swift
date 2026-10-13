import Foundation

/// UI text in the user's language. The German text is the key; translations live in
/// `Resources/<lang>.lproj/Localizable.strings`. Without a translation the German text is used.
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Translated format string (`%@`, `%1$@` …) filled with `args`.
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

public enum Localization {
    /// True when the app runs in German (or no other localization matches).
    public static var isGerman: Bool {
        Bundle.main.preferredLocalizations.first.map { $0.hasPrefix("de") } ?? true
    }
}
