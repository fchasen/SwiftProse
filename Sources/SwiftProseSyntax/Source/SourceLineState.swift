import Foundation

extension NSAttributedString.Key {
    package static let markdownSourceLineState = NSAttributedString.Key("swiftprose.sourceLineState")
}

package enum SourceHTMLEnd: Hashable {
    case blankLine
    case comment
    case processingInstruction
    case declaration
    case cdata
    case rawText

    package func isSatisfied(by line: String) -> Bool {
        switch self {
        case .blankLine: return false
        case .comment: return line.contains("-->")
        case .processingInstruction: return line.contains("?>")
        case .declaration: return line.contains(">")
        case .cdata: return line.contains("]]>")
        case .rawText:
            let lower = line.lowercased()
            return ["</script>", "</pre>", "</style>", "</textarea>"].contains { lower.contains($0) }
        }
    }
}

package struct SourceFenceBlock: Hashable {
    package var marker: unichar
    package var length: Int
    package var group: GroupToken
    package var info: String?
    package var quoteDepth: Int
    package var indent: Int
    package var listColumn: Int

    package init(marker: unichar, length: Int, group: GroupToken, info: String?, quoteDepth: Int, indent: Int, listColumn: Int) {
        self.marker = marker
        self.length = length
        self.group = group
        self.info = info
        self.quoteDepth = quoteDepth
        self.indent = indent
        self.listColumn = listColumn
    }
}

package final class SourceLineState: NSObject {
    package enum Block: Hashable {
        case none
        case fence(SourceFenceBlock)
        case indented(GroupToken)
        case html(SourceHTMLEnd)
    }

    package enum Heading: Hashable {
        case none
        case setext(Int)
        case tableHeader
    }

    package struct Lookahead: Hashable {
        package var heading: Heading = .none
        package var laterRuns: UInt64 = 0

        package static let none = Lookahead()

        package init(heading: Heading = .none, laterRuns: UInt64 = 0) {
            self.heading = heading
            self.laterRuns = laterRuns
        }
    }

    package let block: Block
    package let paragraph: Bool
    package let pipes: Bool
    package let inTable: Bool
    package let quoteDepth: Int
    package let listColumn: Int
    package let codeSpan: Int
    package let lookahead: Lookahead

    package init(
        block: Block = .none,
        paragraph: Bool = false,
        pipes: Bool = false,
        inTable: Bool = false,
        quoteDepth: Int = 0,
        listColumn: Int = 0,
        codeSpan: Int = 0,
        lookahead: Lookahead = .none
    ) {
        self.block = block
        self.paragraph = paragraph
        self.pipes = pipes
        self.inTable = inTable
        self.quoteDepth = quoteDepth
        self.listColumn = listColumn
        self.codeSpan = codeSpan
        self.lookahead = lookahead
        super.init()
    }

    package static let initial = SourceLineState()

    package var inList: Bool { listColumn > 0 }

    package var fenceGroup: GroupToken? {
        if case .fence(let fence) = block { return fence.group }
        return nil
    }

    package var indentedGroup: GroupToken? {
        if case .indented(let group) = block { return group }
        return nil
    }

    package func carriesSameExit(as other: SourceLineState) -> Bool {
        block == other.block
            && paragraph == other.paragraph
            && pipes == other.pipes
            && inTable == other.inTable
            && quoteDepth == other.quoteDepth
            && listColumn == other.listColumn
            && codeSpan == other.codeSpan
    }

    package override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SourceLineState else { return false }
        return other === self || (carriesSameExit(as: other) && lookahead == other.lookahead)
    }

    package override var hash: Int {
        var hasher = Hasher()
        hasher.combine(block)
        hasher.combine(paragraph)
        hasher.combine(pipes)
        hasher.combine(inTable)
        hasher.combine(quoteDepth)
        hasher.combine(listColumn)
        hasher.combine(codeSpan)
        hasher.combine(lookahead)
        return hasher.finalize()
    }
}
