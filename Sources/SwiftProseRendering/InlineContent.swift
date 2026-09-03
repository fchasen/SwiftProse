import Foundation

/// Host-supplied inline rich content embedded in the text — Searchfox links,
/// bug links, user mentions, regular URLs. SwiftProseEditor doesn't depend on
/// BugzillaKit/SearchfoxKit; the host translates its types into one of these
/// cases via `.inlineContentProvider(_:)`.
public enum ProseInlineContent: Sendable, Equatable {
    case url(URL, label: String?)
    case bugLink(id: Int, label: String)
    case userMention(handle: String, displayName: String?)
    case searchfoxLink(url: URL, label: String, symbol: String?)
    /// Escape hatch for content the built-in cases don't describe. `kind` is
    /// stamped onto the document node so the serializer and the host can tell
    /// one flavour of custom content from another.
    case custom(kind: String, label: String, systemImage: String)

    /// Stable identifier stamped into the `inline_content` node's `kind` attr.
    public var kind: String {
        switch self {
        case .url: "url"
        case .bugLink: "bugLink"
        case .userMention: "userMention"
        case .searchfoxLink: "searchfoxLink"
        case let .custom(kind, _, _): kind
        }
    }
}
