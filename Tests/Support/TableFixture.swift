import Foundation
import SwiftProseSyntax
import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

package enum TableFixture {
    package static func rows(_ storage: NSAttributedString) -> [String] {
        LoaderFixture.paragraphs(storage).filter { $0.block?.isTableRow == true }.map(\.text)
    }

    package static func cellStart(_ storage: NSAttributedString, row: Int, column: Int) -> Int {
        let paragraphs = storage.markdownParagraphRanges().filter {
            $0.length > 0 && storage.markdownBlock(at: $0.location)?.isTableRow == true
        }
        return storage.markdownTableCellRanges(inRow: paragraphs[row])[column].location
    }

    package static func cellRange(_ storage: NSAttributedString, row: Int, column: Int) -> NSRange {
        let paragraphs = storage.markdownParagraphRanges().filter {
            $0.length > 0 && storage.markdownBlock(at: $0.location)?.isTableRow == true
        }
        return storage.markdownTableCellRanges(inRow: paragraphs[row])[column]
    }
}
