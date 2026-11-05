import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension NSAttributedString.Key {
    static let markdownCodePrefix = NSAttributedString.Key("swiftprose.codePrefix")
}

struct CodeBody {
    struct Segment {
        var storage: Int
        var body: Int
        var length: Int
    }

    let text: NSString
    let segments: [Segment]

    init(_ storage: NSAttributedString, range: NSRange) {
        let ns = storage.string as NSString
        var segments: [Segment] = []
        var length = 0
        if range.length > 0 {
            storage.enumerateAttribute(.markdownCodePrefix, in: range) { value, run, _ in
                guard value == nil else { return }
                if let last = segments.last, last.storage + last.length == run.location {
                    segments[segments.count - 1].length += run.length
                } else {
                    segments.append(Segment(storage: run.location, body: length, length: run.length))
                }
                length += run.length
            }
        }
        self.segments = segments
        if segments.count == 1, segments[0].length == range.length {
            text = ns.substring(with: range) as NSString
        } else {
            text = segments.map { ns.substring(with: NSRange(location: $0.storage, length: $0.length)) }.joined() as NSString
        }
    }

    func bodyLocation(forStorage location: Int) -> Int {
        for segment in segments {
            if location < segment.storage { return segment.body }
            if location <= segment.storage + segment.length { return segment.body + location - segment.storage }
        }
        return text.length
    }

    func bodyRange(forStorage range: NSRange) -> NSRange {
        let start = bodyLocation(forStorage: range.location)
        let end = bodyLocation(forStorage: NSMaxRange(range))
        return NSRange(location: start, length: max(0, end - start))
    }

    func storageRanges(for local: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        for segment in segments {
            let overlap = NSIntersectionRange(NSRange(location: segment.body, length: segment.length), local)
            guard overlap.length > 0 else { continue }
            ranges.append(NSRange(location: segment.storage + overlap.location - segment.body, length: overlap.length))
        }
        return ranges
    }
}

package struct CodeBlockKey: Hashable {
    let group: GroupToken
    let ordinal: Int
}

package struct CodeBlockExtent: Equatable {
    package let key: CodeBlockKey
    package let body: NSRange
    let language: String?
}

package final class CodeHighlighting {
    private struct Record {
        var language: String?
        var body: NSString
        var session: CodeHighlightSession?
    }

    var highlighter: CodeBlockHighlighter?
    private var records: [CodeBlockKey: Record] = [:]
    private var runCounts: [GroupToken: Int] = [:]
    private(set) var structureScanCount = 0

    var isActive: Bool { highlighter != nil }

    var trackedKeys: Set<CodeBlockKey> { Set(records.keys) }

    func removeAll() {
        records.removeAll()
        runCounts.removeAll()
    }

    func resetAll(in storage: NSMutableAttributedString, baseColor: PlatformColor) {
        records.removeAll()
        guard let highlighter else {
            runCounts.removeAll()
            return
        }
        let extents = Self.extents(in: storage)
        runCounts = Self.runCounts(of: extents)
        for extent in extents {
            reset(extent, in: storage, highlighter: highlighter, baseColor: baseColor)
        }
    }

    func update(
        _ storage: NSMutableAttributedString,
        editedRange: NSRange,
        examined: NSRange,
        charactersEdited: Bool,
        scansStructure: Bool,
        excluding marked: NSRange?,
        baseColor: PlatformColor
    ) {
        guard let highlighter else { return }
        let total = storage.length
        let edited = Normalizer.clamp(editedRange, to: total)
        let scan = Normalizer.clamp(NSUnionRange(edited, Normalizer.clamp(examined, to: total)), to: total)
        var structural = false
        let candidates: [CodeBlockExtent]
        if scansStructure {
            structureScanCount += 1
            let all = Self.extents(in: storage)
            let counts = Self.runCounts(of: all)
            let present = Set(all.map(\.key))
            let dropped = records.keys.filter { !present.contains($0) }
            for key in dropped { records[key] = nil }
            structural = !dropped.isEmpty || all.contains { records[$0.key] == nil }
            let regrouped = Set(counts.keys.filter { counts[$0] != runCounts[$0] })
            runCounts = counts
            candidates = all.filter {
                records[$0.key] == nil || regrouped.contains($0.key.group) || Self.touches($0.body, scan)
            }
        } else {
            candidates = localExtents(in: storage, around: scan)
        }
        for extent in candidates {
            if let marked, Self.touches(extent.body, marked) { continue }
            refresh(
                extent,
                in: storage,
                edited: edited,
                charactersEdited: charactersEdited,
                structural: structural,
                highlighter: highlighter,
                baseColor: baseColor
            )
        }
    }

    private func refresh(
        _ extent: CodeBlockExtent,
        in storage: NSMutableAttributedString,
        edited: NSRange,
        charactersEdited: Bool,
        structural: Bool,
        highlighter: CodeBlockHighlighter,
        baseColor: PlatformColor
    ) {
        let body = CodeBody(storage, range: extent.body)
        guard var record = records[extent.key], record.language == extent.language else {
            reset(extent, body: body, in: storage, highlighter: highlighter, baseColor: baseColor)
            return
        }
        var change = Self.difference(from: record.body, to: body.text, bodyStart: 0, hint: body.bodyRange(forStorage: edited))
        if change != nil, structural {
            reset(extent, body: body, in: storage, highlighter: highlighter, baseColor: baseColor)
            return
        }
        if change == nil {
            let identity = NSIntersectionRange(edited, extent.body)
            guard charactersEdited, identity.length > 0 else { return }
            let local = body.bodyRange(forStorage: identity)
            guard local.length > 0 else { return }
            change = (local, body.text.substring(with: local))
        }
        guard let change else { return }
        record.body = body.text
        records[extent.key] = record
        let replacementLength = (change.replacement as NSString).length
        guard let session = record.session else {
            paint(NSRange(location: change.range.location, length: replacementLength), runs: [], body: body, in: storage, baseColor: baseColor)
            return
        }
        let result = session.didEdit(replacedRange: change.range, replacement: change.replacement, body: body.text as String)
        paint(result.invalidatedRange, runs: result.runs, body: body, in: storage, baseColor: baseColor)
    }

    private func reset(
        _ extent: CodeBlockExtent,
        in storage: NSMutableAttributedString,
        highlighter: CodeBlockHighlighter,
        baseColor: PlatformColor
    ) {
        reset(extent, body: CodeBody(storage, range: extent.body), in: storage, highlighter: highlighter, baseColor: baseColor)
    }

    private func reset(
        _ extent: CodeBlockExtent,
        body: CodeBody,
        in storage: NSMutableAttributedString,
        highlighter: CodeBlockHighlighter,
        baseColor: PlatformColor
    ) {
        let text = body.text as String
        let session = highlighter.makeSession(language: extent.language, body: text)
        let runs = session?.reset(body: text) ?? []
        records[extent.key] = Record(language: extent.language, body: body.text, session: session)
        paint(NSRange(location: 0, length: body.text.length), runs: runs, body: body, in: storage, baseColor: baseColor)
    }

    private func paint(
        _ invalidated: NSRange,
        runs: [CodeHighlightRun],
        body: CodeBody,
        in storage: NSMutableAttributedString,
        baseColor: PlatformColor
    ) {
        let bodyLength = body.text.length
        let local = Normalizer.clamp(invalidated, to: bodyLength)
        guard local.length > 0 else { return }
        for range in body.storageRanges(for: local) {
            storage.addAttribute(.foregroundColor, value: baseColor, range: range)
        }
        for run in runs {
            let clipped = NSIntersectionRange(Normalizer.clamp(run.range, to: bodyLength), local)
            guard clipped.length > 0 else { continue }
            for range in body.storageRanges(for: clipped) {
                storage.addAttribute(.foregroundColor, value: run.color, range: range)
            }
        }
    }

    private func localExtents(in storage: NSAttributedString, around scan: NSRange) -> [CodeBlockExtent] {
        let total = storage.length
        guard total > 0 else { return [] }
        let ns = storage.string as NSString
        let paragraphs = ns.paragraphRange(for: Normalizer.clamp(scan, to: total))
        var result: [CodeBlockExtent] = []
        var location = paragraphs.location
        while location < NSMaxRange(paragraphs) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = max(NSMaxRange(paragraph), location + 1) }
            guard let block = storage.markdownBlock(at: paragraph.location), let group = block.codeGroup else { continue }
            if let last = result.last, NSMaxRange(last.body) >= paragraph.location, last.key.group == group { continue }
            if (runCounts[group] ?? 0) > 1 {
                return Self.extents(in: storage).filter { Self.touches($0.body, scan) }
            }
            var start = paragraph.location
            while start > 0 {
                let previous = ns.paragraphRange(for: NSRange(location: start - 1, length: 0))
                guard storage.markdownBlock(at: previous.location)?.codeGroup == group else { break }
                start = previous.location
            }
            var end = NSMaxRange(paragraph)
            while end < total {
                let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
                guard storage.markdownBlock(at: next.location)?.codeGroup == group else { break }
                end = NSMaxRange(next)
            }
            let first = storage.markdownBlock(at: start)
            result.append(CodeBlockExtent(
                key: CodeBlockKey(group: group, ordinal: 0),
                body: Self.bodyRange(start: start, end: end, in: ns),
                language: first?.codeLanguage
            ))
        }
        return result
    }

    package static func extents(in storage: NSAttributedString) -> [CodeBlockExtent] {
        let total = storage.length
        guard total > 0 else { return [] }
        let ns = storage.string as NSString
        var result: [CodeBlockExtent] = []
        var ordinals: [GroupToken: Int] = [:]
        var current: (group: GroupToken, language: String?, start: Int, end: Int)?
        func flush() {
            guard let open = current else { return }
            let ordinal = ordinals[open.group, default: 0]
            ordinals[open.group] = ordinal + 1
            result.append(CodeBlockExtent(
                key: CodeBlockKey(group: open.group, ordinal: ordinal),
                body: bodyRange(start: open.start, end: open.end, in: ns),
                language: open.language
            ))
            current = nil
        }
        storage.enumerateAttribute(.markdownBlock, in: NSRange(location: 0, length: total)) { value, run, _ in
            guard let block = value as? MarkdownBlock, let group = block.codeGroup else { return }
            let paragraphs = ns.paragraphRange(for: run)
            if let open = current, open.group == group, paragraphs.location <= open.end {
                current?.end = max(open.end, NSMaxRange(paragraphs))
            } else {
                flush()
                current = (group, block.codeLanguage, paragraphs.location, NSMaxRange(paragraphs))
            }
        }
        flush()
        return result
    }

    private static func runCounts(of extents: [CodeBlockExtent]) -> [GroupToken: Int] {
        extents.reduce(into: [:]) { $0[$1.key.group, default: 0] += 1 }
    }

    private static func bodyRange(start: Int, end: Int, in ns: NSString) -> NSRange {
        var bodyEnd = end
        if bodyEnd > start, ns.character(at: bodyEnd - 1) == MarkdownParagraph.separator { bodyEnd -= 1 }
        return NSRange(location: start, length: bodyEnd - start)
    }

    static func touches(_ range: NSRange, _ other: NSRange) -> Bool {
        other.location <= NSMaxRange(range) && NSMaxRange(other) >= range.location
    }

    static func difference(
        from old: NSString,
        to new: NSString,
        bodyStart: Int,
        hint: NSRange
    ) -> (range: NSRange, replacement: String)? {
        let oldLength = old.length
        let newLength = new.length
        if oldLength == newLength, old.isEqual(new) { return nil }
        let shorter = min(oldLength, newLength)
        let prefixCap = max(0, min(shorter, hint.location - bodyStart))
        var prefix = 0
        while prefix < prefixCap, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        let suffixCap = max(0, min(shorter - prefix, bodyStart + newLength - NSMaxRange(hint)))
        var suffix = 0
        while suffix < suffixCap, old.character(at: oldLength - suffix - 1) == new.character(at: newLength - suffix - 1) {
            suffix += 1
        }
        let replaced = NSRange(location: prefix, length: oldLength - prefix - suffix)
        let inserted = NSRange(location: prefix, length: newLength - prefix - suffix)
        return (replaced, new.substring(with: inserted))
    }
}
