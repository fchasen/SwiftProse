import Foundation
import SwiftUI
import SwiftProseView

struct ProseStatusBar: View {
    let items: [SwiftProseEditor.StatusItem]
    let text: String
    let selection: NSRange

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items.indices, id: \.self) { i in
                view(for: items[i])
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func view(for item: SwiftProseEditor.StatusItem) -> some View {
        switch item {
        case .words:
            Text("\(wordCount) words")
        case .characters:
            Text("\(characterCount) chars")
        case .cursor:
            Text("\(line):\(column)")
        }
    }

    private var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }

    private var characterCount: Int { text.count }

    private var line: Int {
        let ns = text as NSString
        let upTo = ns.substring(to: min(max(0, selection.location), ns.length)) as NSString
        return upTo.components(separatedBy: "\n").count
    }

    private var column: Int {
        let ns = text as NSString
        let upTo = min(max(0, selection.location), ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: upTo, length: 0))
        return upTo - lineRange.location + 1
    }
}
