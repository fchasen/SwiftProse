import Foundation

public enum ProseInlineContent: Sendable, Equatable {
    case url(URL, label: String?)
    case userMention(handle: String, displayName: String?)
    case custom(kind: String, label: String, systemImage: String)

    public var kind: String {
        switch self {
        case .url: "url"
        case .userMention: "userMention"
        case let .custom(kind, _, _): kind
        }
    }
}
