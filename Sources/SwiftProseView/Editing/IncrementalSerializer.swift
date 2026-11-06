import SwiftProseSyntax
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

package struct SerializationStats: Equatable, Sendable {
    package var rebuilds = 0
    package var splices = 0
    package var fallbacks = 0
    package var unitsRead = 0
    package var unitsWritten = 0
    package var drifts = 0
}

final class IncrementalSerializer {
    private struct Entry {
        var unit: TopLevelUnit
        var entry: TopLevelContext
        var exit: TopLevelContext
        var text: String?

        var bytes: Int { text.map { $0.utf8.count + 2 } ?? 0 }
    }

    private var entries: [Entry] = []
    private var spans: [Int] = []
    private var bytes: [Int] = []
    private var covered = 0
    private var body = ""
    private var isValid = false
    private var dirty: NSRange?
    private var dirtyDelta = 0
    private(set) var lastDirty: NSRange?
    private(set) var lastFallback: String?
    private(set) var stats = SerializationStats()
    private(set) var driftLog: [String] = []
    var verifies = false

    func recordEdit(_ range: NSRange, changeInLength delta: Int) {
        if let dirty {
            self.dirty = dirty.merged(withEdit: range, changeInLength: delta)
        } else {
            dirty = range
        }
        dirtyDelta += delta
    }

    @discardableResult
    func rebuild(_ storage: NSAttributedString) -> String {
        stats.rebuilds += 1
        let scan = StorageReader().units(in: storage, from: 0, previous: nil)
        stats.unitsRead += scan.units.count
        entries = Self.written(scan.units, after: .start)
        stats.unitsWritten += entries.count
        spans = entries.map(\.unit.length)
        bytes = entries.map(\.bytes)
        body = Self.joined(entries[...])
        covered = storage.length
        lastDirty = dirty
        dirty = nil
        dirtyDelta = 0
        isValid = true
        return output
    }

    func markdown(from storage: NSAttributedString) -> String {
        if let textStorage = storage as? NSTextStorage, !textStorage.editedMask.isEmpty {
            lastFallback = "storage has an unprocessed edit"
            stats.fallbacks += 1
            return MarkdownWriter().markdown(from: storage)
        }
        guard isValid else { return rebuild(storage) }
        guard dirty != nil else { return output }
        guard !entries.isEmpty else { return rebuild(storage) }
        let failure = covered + dirtyDelta == storage.length
            ? splice(storage)
            : "recorded edits change the length by \(dirtyDelta), storage went from \(covered) to \(storage.length)"
        if let failure {
            lastFallback = failure
            stats.fallbacks += 1
            return rebuild(storage)
        }
        stats.splices += 1
        if verifies, let drift = drift(in: storage) {
            stats.drifts += 1
            driftLog.append(drift)
            return rebuild(storage)
        }
        return output
    }

    func drift(in storage: NSAttributedString) -> String? {
        let spliced = markdown(from: storage)
        let scan = StorageReader().units(in: storage, from: 0, previous: nil)
        let fresh = Self.written(scan.units, after: .start)
        let dirtyLabel = lastDirty.map { "dirty \($0)" } ?? "no dirty range"
        var location = 0
        for (index, unit) in fresh.enumerated() {
            guard index < entries.count else {
                return "unit \(index) at \(location) is missing from the cache (\(entries.count) cached, \(fresh.count) read), \(dirtyLabel)"
            }
            let cached = entries[index]
            if cached.unit.length != unit.unit.length || cached.unit.leading != unit.unit.leading {
                return "unit \(index) at \(location) spans \(cached.unit.length) cached, \(unit.unit.length) read, \(dirtyLabel)"
            }
            if cached.text != unit.text {
                return "unit \(index) at \(location) wrote «\(cached.text ?? "nil")» cached, «\(unit.text ?? "nil")» read, \(dirtyLabel)"
            }
            location += unit.unit.length
        }
        if entries.count != fresh.count {
            return "cache holds \(entries.count) units, the reader \(fresh.count), \(dirtyLabel)"
        }
        if spliced != MarkdownWriter().markdown(from: storage) {
            return "spliced output differs from MarkdownWriter, \(dirtyLabel)"
        }
        return nil
    }

    private var output: String {
        guard body.utf8.count > 2 else { return "" }
        return String(body[body.utf8.index(body.startIndex, offsetBy: 2)...])
    }

    private static func written(_ units: [TopLevelUnit], after context: TopLevelContext) -> [Entry] {
        var context = context
        return units.map { unit in
            let written = MarkdownWriter.writeTopLevel(unit.block, after: context)
            defer { context = written.context }
            return Entry(unit: unit, entry: context, exit: written.context, text: written.text)
        }
    }

    private static func joined(_ entries: ArraySlice<Entry>) -> String {
        var joined = ""
        for entry in entries {
            guard let text = entry.text else { continue }
            joined += "\n\n"
            joined += text
        }
        return joined
    }

    private func splice(_ storage: NSAttributedString) -> String? {
        guard let dirty else { return nil }
        let delta = dirtyDelta
        let newLength = storage.length
        let editStart = dirty.location
        let editEnd = NSMaxRange(dirty)
        let oldEditEnd = editEnd - delta
        guard editStart >= 0, editEnd <= newLength, oldEditEnd >= editStart, oldEditEnd <= covered else {
            return "dirty range \(dirty) is outside the storage"
        }

        var starts = [Int](repeating: 0, count: spans.count)
        var position = 0
        for index in spans.indices {
            starts[index] = position
            position += spans[index]
        }
        guard position == covered else { return "unit spans cover \(position) of \(covered)" }

        let first = Self.unitIndex(containing: editStart, starts: starts)
        let low = first > 0 && entries[first - 1].unit.canAbsorbFollowingParagraphs ? first - 1 : first
        let entering = low > 0 ? entries[low - 1].exit : TopLevelContext.start
        let previousList = low > 0 ? entries[low - 1].unit.list : nil
        let leadingOfFirst = entries[0].unit.leading
        let scan = StorageReader().units(in: storage, from: starts[low], previous: previousList) { boundary in
            guard boundary >= editEnd, let index = Self.exactIndex(of: boundary - delta, starts: starts), index >= low else {
                return false
            }
            return index > 0 || leadingOfFirst == 0
        }
        stats.unitsRead += scan.units.count

        let high: Int
        if scan.stopped {
            guard let index = Self.exactIndex(of: scan.end - delta, starts: starts) else {
                return "scan stopped off a unit boundary at \(scan.end)"
            }
            high = index
        } else {
            high = entries.count
        }
        let oldEnd = high < entries.count ? starts[high] : covered
        guard scan.end - scan.start == oldEnd - starts[low] + delta else {
            return "scan covered \(scan.end - scan.start), the replaced units \(oldEnd - starts[low] + delta)"
        }

        var outputStart = 0
        for index in 0..<low { outputStart += bytes[index] }
        var replacedBytes = 0
        for index in low..<high { replacedBytes += bytes[index] }

        let fresh = Self.written(scan.units, after: entering)
        stats.unitsWritten += fresh.count
        var context = fresh.last?.exit ?? entering

        let orphaned = fresh.isEmpty ? scan.end - scan.start : 0
        entries.replaceSubrange(low..<high, with: fresh)
        spans.replaceSubrange(low..<high, with: fresh.map(\.unit.length))
        bytes.replaceSubrange(low..<high, with: fresh.map(\.bytes))
        var cursor = low + fresh.count
        if orphaned > 0 {
            if low > 0 {
                entries[low - 1].unit.length += orphaned
                spans[low - 1] += orphaned
            } else if cursor < entries.count {
                entries[cursor].unit.length += orphaned
                entries[cursor].unit.leading += orphaned
                spans[cursor] += orphaned
            }
        }
        var previous = cursor > 0 ? entries[cursor - 1].unit.list : nil
        while cursor < entries.count {
            var entry = entries[cursor]
            let separationChanged = entry.unit.separate(from: previous)
            guard separationChanged || entry.entry != context else { break }
            replacedBytes += bytes[cursor]
            let written = MarkdownWriter.writeTopLevel(entry.unit.block, after: context)
            entry.entry = context
            entry.exit = written.context
            entry.text = written.text
            entries[cursor] = entry
            bytes[cursor] = entry.bytes
            stats.unitsWritten += 1
            previous = entry.unit.list
            context = written.context
            cursor += 1
        }

        let utf8 = body.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: outputStart)
        let upper = utf8.index(lower, offsetBy: replacedBytes)
        body.replaceSubrange(lower..<upper, with: Self.joined(entries[low..<cursor]))

        var total = 0
        for span in spans { total += span }
        guard entries.isEmpty || total == newLength else {
            return "unit spans cover \(total) of \(newLength) after the splice"
        }
        covered = newLength
        lastDirty = dirty
        self.dirty = nil
        dirtyDelta = 0
        return nil
    }

    private static func unitIndex(containing location: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static func exactIndex(of location: Int, starts: [Int]) -> Int? {
        let index = unitIndex(containing: location, starts: starts)
        return starts[index] == location ? index : nil
    }
}
