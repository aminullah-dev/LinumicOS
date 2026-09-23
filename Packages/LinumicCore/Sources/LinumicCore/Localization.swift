import Foundation

/// Looks up a display string in the host app's string table (`Localizable.xcstrings`).
/// LinumicCore stays UI-free. The app bundle supplies the Dari translations, and outside
/// the app (e.g. `swift test`) the English key comes back unchanged.
@inline(__always)
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Formats a localized template, e.g. `LF("Repository %@", name)`.
public func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}
