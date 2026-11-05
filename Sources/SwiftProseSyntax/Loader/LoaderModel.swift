import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct LoaderRun {
    let text: String
    let intent: PresentationIntent?
    let inline: InlinePresentationIntent
    let link: URL?
    let imageURL: URL?
    let position: AttributedString.MarkdownSourcePosition?

    init(
        text: String,
        intent: PresentationIntent? = nil,
        inline: InlinePresentationIntent = [],
        link: URL? = nil,
        imageURL: URL? = nil,
        position: AttributedString.MarkdownSourcePosition? = nil
    ) {
        self.text = text
        self.intent = intent
        self.inline = inline
        self.link = link
        self.imageURL = imageURL
        self.position = position
    }

    static func runs(of parsed: AttributedString) -> [LoaderRun] {
        parsed.runs.map { run in
            LoaderRun(
                text: String(parsed[run.range].characters),
                intent: run.presentationIntent,
                inline: run.inlinePresentationIntent ?? [],
                link: run.link,
                imageURL: run.imageURL,
                position: run.markdownSourcePosition.flatMap(validPosition)
            )
        }
    }

    static func validPosition(_ position: AttributedString.MarkdownSourcePosition) -> AttributedString.MarkdownSourcePosition? {
        guard position.startLine >= 1, position.startColumn >= 1, position.endLine >= position.startLine else { return nil }
        return position
    }

    var lineSpan: ClosedRange<Int>? {
        guard let position else { return nil }
        let end = position.endColumn == 0 ? max(position.startLine, position.endLine - 1) : position.endLine
        return position.startLine...max(position.startLine, end)
    }
}

enum LoaderLeafKind {
    case paragraph
    case heading(Int)
    case code(String?)
    case thematicBreak
    case table([PresentationIntent.TableColumn])
    case html

    var isTextual: Bool {
        switch self {
        case .paragraph, .heading: true
        default: false
        }
    }
}

package final class MarkdownTextList: NSTextList {
    package static func effectiveTextLists(in storage: NSAttributedString, at index: Int) -> [NSTextList] {
        guard index >= 0, index < storage.length,
              let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        else { return [] }
        return style.textLists.filter { !$0.markerFormat.rawValue.isEmpty }
    }

    package var sourceMarker: UInt8?

    package static func sourceMarker(of list: NSTextList) -> UInt8? {
        (list as? MarkdownTextList)?.sourceMarker
    }

    package static func areDistinct(_ lhs: UInt8?, _ rhs: UInt8?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }
}

final class LoaderItem {
    let key: Int
    let list: NSTextList
    var marker: PrefixToken.Kind? {
        didSet {
            guard let list = list as? MarkdownTextList, list.sourceMarker == nil else { return }
            switch marker {
            case .bullet(let byte)?: list.sourceMarker = byte
            case .ordered(_, let delimiter)?: list.sourceMarker = delimiter
            default: break
            }
        }
    }
    var markerColumn: Int?
    var contentColumn: Int?

    init(key: Int, list: NSTextList) {
        self.key = key
        self.list = list
    }
}

enum LoaderLink {
    case quote(GroupToken)
    case item(LoaderItem)

    var container: MarkdownBlock.Container {
        switch self {
        case .quote(let token): .quote(token)
        case .item: .listItem
        }
    }

    func isSame(as other: LoaderLink) -> Bool {
        switch (self, other) {
        case (.quote(let a), .quote(let b)): a == b
        case (.item(let a), .item(let b)): a === b
        default: false
        }
    }
}

final class LoaderLeaf {
    var kind: LoaderLeafKind
    var key: Int
    var path: [PresentationIntent.IntentType]
    var runs: [LoaderRun]
    var lines: ClosedRange<Int>?
    var chain: [LoaderLink] = []
    var newItemKeys: Set<Int> = []
    var isContinuation = false
    var thematicSource: String?
    var isRecovered = false

    init(kind: LoaderLeafKind, key: Int, path: [PresentationIntent.IntentType], runs: [LoaderRun]) {
        self.kind = kind
        self.key = key
        self.path = path
        self.runs = runs
        self.lines = nil
        for run in runs {
            extend(with: run.lineSpan)
        }
    }

    func extend(with span: ClosedRange<Int>?) {
        guard let span else { return }
        if let lines {
            self.lines = min(lines.lowerBound, span.lowerBound)...max(lines.upperBound, span.upperBound)
        } else {
            self.lines = span
        }
    }

    var containers: [MarkdownBlock.Container] { chain.map(\.container) }

    var textLists: [NSTextList] {
        chain.compactMap {
            if case .item(let item) = $0 { return item.list }
            return nil
        }
    }
}

struct LoaderReport: Sendable {
    var fallbackRuns: Int = 0
    var recoveredLines: [Int] = []
}
