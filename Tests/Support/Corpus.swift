import Foundation
import SwiftProseSyntax
import SwiftProseView

package enum Corpus {
    package static let labelPattern = #"\{nav(?:\s+|\s*,\s*)icon=([A-Za-z0-9_\-]+)\s*,\s*name=([^}\n]*)\}"#
    package static let labelKind = "test.commentLabel"

    package static let labelRules: [InlineContentRule] = [
        InlineContentRule(id: labelKind, pattern: labelPattern) { match in
            guard let icon = match.capture(1), !icon.isEmpty else { return nil }
            return .custom(kind: labelKind, label: match.capture(2) ?? "", systemImage: "tag")
        }
    ]

    package static let labelProvider: ProseInlineContentProvider = { content in
        ChipAttachment.make(for: content)
    }

    package static func load(_ markdown: String, labels: Bool = false) -> NSMutableAttributedString {
        MarkdownLoader(
            inlineContentRules: labels ? labelRules : [],
            inlineContentProvider: labels ? labelProvider : nil
        ).load(markdown)
    }

    package static func write(_ storage: NSAttributedString) -> String {
        MarkdownWriter().markdown(from: storage)
    }

    package static func roundTrip(_ markdown: String, labels: Bool = false) -> String {
        write(load(markdown, labels: labels))
    }
}
