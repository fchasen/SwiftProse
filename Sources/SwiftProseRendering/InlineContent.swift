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
}
