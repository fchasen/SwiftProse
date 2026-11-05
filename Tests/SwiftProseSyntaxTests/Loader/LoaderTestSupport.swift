import Foundation
@testable import SwiftProseSyntax
import SwiftProseTestSupport

extension LoaderFixture {
    static func load(
        _ markdown: String,
        rules: [InlineContentRule] = [],
        provider: ProseInlineContentProvider? = nil
    ) -> (storage: NSMutableAttributedString, report: LoaderReport) {
        MarkdownLoader(inlineContentRules: rules, inlineContentProvider: provider).loadWithReport(markdown)
    }

    static func texts(_ markdown: String) -> [String] {
        paragraphs(load(markdown).storage).map(\.text)
    }
}
