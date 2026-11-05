import Foundation

public struct EditorDocument: Hashable, Sendable {
    public var blocks: [Block]

    public init(blocks: [Block] = []) {
        self.blocks = blocks
    }

    public indirect enum Block: Hashable, Sendable {
        case paragraph([InlineRun])
        case heading(level: Int, [InlineRun])
        case code(CodeBlock)
        case thematicBreak
        case atom(Atom)
        case quote([Block])
        case list(ListBlock)
        case table(TableBlock)
    }

    public typealias TableCell = [InlineRun]

    public struct TableBlock: Hashable, Sendable {
        public var alignments: [TableColumnAlignment]
        public var header: [TableCell]
        public var body: [[TableCell]]

        public init(alignments: [TableColumnAlignment], header: [TableCell], body: [[TableCell]] = []) {
            self.alignments = alignments
            self.header = header
            self.body = body
        }

        public var columnCount: Int {
            max(1, alignments.count, header.count, body.map(\.count).max() ?? 0)
        }
    }

    public struct CodeBlock: Hashable, Sendable {
        public var language: String?
        public var lines: [String]

        public init(language: String? = nil, lines: [String]) {
            self.language = language
            self.lines = lines
        }
    }

    public struct Atom: Hashable, Sendable {
        public var source: String
        public var kind: String

        public init(source: String, kind: String) {
            self.source = source
            self.kind = kind
        }
    }

    public enum ListKind: Hashable, Sendable {
        case bullet
        case ordered(start: Int)

        public var isOrdered: Bool {
            if case .ordered = self { return true }
            return false
        }
    }

    public struct ListBlock: Hashable, Sendable {
        public var kind: ListKind
        public var items: [ListItem]
        public var separatesFromPrevious: Bool

        public init(kind: ListKind, items: [ListItem], separatesFromPrevious: Bool = false) {
            self.kind = kind
            self.items = items
            self.separatesFromPrevious = separatesFromPrevious
        }
    }

    public struct ListItem: Hashable, Sendable {
        public var task: TaskState?
        public var blocks: [Block]

        public init(task: TaskState? = nil, blocks: [Block]) {
            self.task = task
            self.blocks = blocks
        }
    }

    public struct InlineMarks: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let strong = InlineMarks(rawValue: 1 << 0)
        public static let emphasis = InlineMarks(rawValue: 1 << 1)
        public static let code = InlineMarks(rawValue: 1 << 2)
        public static let strikethrough = InlineMarks(rawValue: 1 << 3)

        public init(intent: MarkdownInlineIntent) {
            var marks: InlineMarks = []
            if intent.contains(.stronglyEmphasized) { marks.insert(.strong) }
            if intent.contains(.emphasized) { marks.insert(.emphasis) }
            if intent.contains(.code) { marks.insert(.code) }
            if intent.contains(.strikethrough) { marks.insert(.strikethrough) }
            self = marks
        }

        public var intent: MarkdownInlineIntent {
            var intent: MarkdownInlineIntent = []
            if contains(.strong) { intent.insert(.stronglyEmphasized) }
            if contains(.emphasis) { intent.insert(.emphasized) }
            if contains(.code) { intent.insert(.code) }
            if contains(.strikethrough) { intent.insert(.strikethrough) }
            return intent
        }
    }

    public struct InlineRun: Hashable, Sendable {
        public enum Content: Hashable, Sendable {
            case text(String)
            case literal(text: String, source: String)
            case softBreak
            case hardBreak
            case atom(Atom)
        }

        public var content: Content
        public var marks: InlineMarks
        public var link: String?

        public init(_ content: Content, marks: InlineMarks = [], link: String? = nil) {
            self.content = content
            self.marks = marks
            self.link = link
        }

        public static func text(_ string: String, marks: InlineMarks = [], link: String? = nil) -> InlineRun {
            InlineRun(.text(string), marks: marks, link: link)
        }
    }
}
