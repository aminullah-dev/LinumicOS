import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// File and clipboard helpers for the licence centre. The app is sandboxed: it can only read files
/// the owner picks and write where the owner saves.
enum LicenceFiles {
    static let lnmlicType = UTType(filenameExtension: "lnmlic") ?? .plainText
    static let pemType = UTType(filenameExtension: "pem") ?? .data

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Reads a picked file (security-scoped when it comes from a picker).
    static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }

    #if os(macOS)
    /// NSOpenPanel for the private key of one product. Returns the PEM text, or nil if cancelled.
    @MainActor
    static func chooseSigningKey(for productName: String) throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [pemType, .data]
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose the \(productName) private key (<product>-private.pem). It is checked against the public key built into the app and stored only in this Mac's Keychain.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try read(url)
    }

    /// NSOpenPanel for issued.csv and .lnmlic files.
    @MainActor
    static func chooseLedgerFiles() throws -> [(name: String, text: String)] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.commaSeparatedText, lnmlicType, .plainText]
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose issued.csv from ~/.linumic/licenses, and optionally the .lnmlic files next to it so their keys are attached.")
        guard panel.runModal() == .OK else { return [] }
        return try panel.urls.map { ($0.lastPathComponent, try read($0)) }
    }

    /// NSSavePanel; writes `text` where the owner chooses. Returns false if cancelled.
    @MainActor
    @discardableResult
    static func save(_ text: String, suggestedName: String, type: UTType) throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try Data(text.utf8).write(to: url, options: [.atomic])
        return true
    }
    #endif
}

/// A text file for `fileExporter` on iOS.
struct LicenceTextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .commaSeparatedText]
    static let writableContentTypes: [UTType] = [.plainText, .commaSeparatedText, LicenceFiles.lnmlicType]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
