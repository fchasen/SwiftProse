import SwiftProseSyntax
import SwiftProseRendering
import Foundation
import UniformTypeIdentifiers

public struct PastedImage: Sendable, Equatable {
    public var data: Data
    public var contentType: UTType
    public var suggestedName: String?

    public init(data: Data, contentType: UTType, suggestedName: String? = nil) {
        self.data = data
        self.contentType = contentType
        self.suggestedName = suggestedName
    }
}

enum PastedImagePolicy {
    static let dataTypes: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .heif, .tiff]

    static func images(
        hasMarkdown: Bool,
        forcePlain: Bool,
        plainText: String?,
        fileURLs: [URL],
        dataImages: () -> [PastedImage]
    ) -> [PastedImage] {
        guard !hasMarkdown, !forcePlain else { return [] }
        if !fileURLs.isEmpty {
            return fileURLs.compactMap(image(fromFileAt:))
        }
        if let text = plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, !isSingleURL(text) {
            return []
        }
        return dataImages()
    }

    static func preferredDataType(in typeIdentifiers: [String]) -> UTType? {
        let available = Set(typeIdentifiers)
        return dataTypes.first { available.contains($0.identifier) }
    }

    static func isSingleURL(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    static func image(fromFileAt url: URL) -> PastedImage? {
        guard url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .image),
              let data = try? Data(contentsOf: url), !data.isEmpty
        else { return nil }
        return PastedImage(data: data, contentType: type, suggestedName: url.lastPathComponent)
    }
}
