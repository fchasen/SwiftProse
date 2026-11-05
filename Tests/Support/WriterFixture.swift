import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

package final class WriterTestAtom: NSTextAttachment, ProseSourceAttachment {
    package var markdownSource: String
    package var contentKind: String

    package init(source: String, kind: String) {
        markdownSource = source
        contentKind = kind
        super.init(data: nil, ofType: nil)
    }

    package required init?(coder: NSCoder) {
        fatalError("unused")
    }
}

package enum WF {
    package typealias Marks = EditorDocument.InlineMarks

    package struct Para {
        package var content: [NSAttributedString]
        package var block: MarkdownBlock
        package var lists: [NSTextList]

        package init(content: [NSAttributedString], block: MarkdownBlock, lists: [NSTextList]) {
            self.content = content
            self.block = block
            self.lists = lists
        }
    }

    package static func t(_ string: String, _ marks: Marks = [], link: String? = nil, literal: String? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if !marks.isEmpty { attributes[.markdownInlineIntent] = marks.intent.attributeValue }
        if let link { attributes[.link] = link }
        if let literal { attributes[.markdownLiteral] = literal }
        return NSAttributedString(string: string, attributes: attributes)
    }

    package static var soft: NSAttributedString {
        NSAttributedString(string: MarkdownBreak.string, attributes: [
            .markdownInlineIntent: MarkdownInlineIntent.softBreak.attributeValue
        ])
    }

    package static var hard: NSAttributedString {
        NSAttributedString(string: MarkdownBreak.string)
    }

    package static func atom(_ source: String, kind: String = "test.atom", _ marks: Marks = []) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: WriterTestAtom(source: source, kind: kind))
        if !marks.isEmpty {
            string.addAttribute(.markdownInlineIntent, value: marks.intent.attributeValue, range: NSRange(location: 0, length: string.length))
        }
        return string
    }

    package static func p(_ content: NSAttributedString..., block: MarkdownBlock = .paragraph, lists: [NSTextList] = []) -> Para {
        Para(content: content, block: block, lists: lists)
    }

    package static func p(_ text: String, block: MarkdownBlock = .paragraph, lists: [NSTextList] = []) -> Para {
        Para(content: text.isEmpty ? [] : [t(text)], block: block, lists: lists)
    }

    package static func item(_ text: String, _ lists: [NSTextList], task: TaskState? = nil, continuation: Bool = false, quotes: [GroupToken] = []) -> Para {
        let containers = quotes.map(MarkdownBlock.Container.quote) + lists.map { _ in .listItem }
        let block = MarkdownBlock(containers: containers, isContinuation: continuation, task: task)
        return p(text, block: block, lists: lists)
    }

    package static func code(_ line: String, _ group: GroupToken, language: String? = nil, containers: [MarkdownBlock.Container] = [], lists: [NSTextList] = [], continuation: Bool = false) -> Para {
        let block = MarkdownBlock(leaf: .code(language: language, group: group), containers: containers, isContinuation: continuation)
        return p(line, block: block, lists: lists)
    }

    package static func bullet() -> NSTextList {
        NSTextList(markerFormat: .disc, options: 0)
    }

    package static func ordered(_ start: Int = 1) -> NSTextList {
        let list = NSTextList(markerFormat: .decimal, options: 0)
        list.startingItemNumber = start
        return list
    }

    package static func carrier() -> NSTextList {
        NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: ""), options: 0)
    }

    package static func storage(_ paragraphs: [Para], trailingNewline: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let start = result.length
            for piece in paragraph.content { result.append(piece) }
            if index < paragraphs.count - 1 || trailingNewline {
                result.append(NSAttributedString(string: "\n"))
            }
            let range = NSRange(location: start, length: result.length - start)
            guard range.length > 0 else { continue }
            result.addAttribute(.markdownBlock, value: paragraph.block, range: range)
            if !paragraph.lists.isEmpty {
                let style = NSMutableParagraphStyle()
                style.textLists = paragraph.lists
                result.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        return result
    }

    package static func write(_ paragraphs: Para..., trailingNewline: Bool = false) -> String {
        write(paragraphs, trailingNewline: trailingNewline)
    }

    package static func write(_ paragraphs: [Para], trailingNewline: Bool = false) -> String {
        MarkdownWriter().markdown(from: storage(paragraphs, trailingNewline: trailingNewline))
    }

    package static func inline(_ content: NSAttributedString...) -> String {
        write([Para(content: content, block: .paragraph, lists: [])])
    }
}
