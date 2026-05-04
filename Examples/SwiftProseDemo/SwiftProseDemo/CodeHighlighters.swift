import Foundation
import SwiftProse
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterJavaScript
import TreeSitterCSS
import TreeSitterHTML

/// Builds a `TreeSitterCodeBlockHighlighter` configured with the four
/// languages bundled into the demo app: swift, javascript, css, html.
///
/// The corresponding `highlights.scm` queries are vendored under
/// `Resources/queries/<lang>.scm` because the upstream tree-sitter SwiftPM
/// packages don't expose `Bundle.module` access from a downstream target.
enum DemoCodeHighlighter {
    /// Returns nil if any registration fails — typically a `highlights.scm`
    /// missing from the bundle, which would silently disable highlighting if
    /// we returned a partial registry.
    static func make() -> CodeBlockHighlighter? {
        let highlighter = TreeSitterCodeBlockHighlighter()
        let registrations: [(name: String, language: Language, queryResource: String, aliases: [String])] = [
            ("swift", Language(language: tree_sitter_swift()), "swift",
             []),
            ("javascript", Language(language: tree_sitter_javascript()), "javascript",
             ["js", "jsx", "mjs"]),
            ("css", Language(language: tree_sitter_css()), "css",
             []),
            ("html", Language(language: tree_sitter_html()), "html",
             ["htm"])
        ]
        for r in registrations {
            guard let url = Bundle.main.url(
                forResource: r.queryResource,
                withExtension: "scm",
                subdirectory: "queries"
            ),
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            do {
                try highlighter.register(language: r.name, language: r.language, queryData: data)
                for alias in r.aliases {
                    try highlighter.register(language: alias, language: r.language, queryData: data)
                }
            } catch {
                return nil
            }
        }
        return highlighter
    }
}
