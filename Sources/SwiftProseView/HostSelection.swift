import SwiftProseSyntax
import SwiftProseRendering
import Foundation

#if canImport(AppKit) && os(macOS)
import AppKit

extension NSTextView {
    func adoptSelection(_ range: NSRange) {
        let clamped = Normalizer.clamp(range, to: textStorage?.length ?? 0)
        guard clamped != selectedRange() else { return }
        setSelectedRange(clamped)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.scrollRangeToVisible(self.selectedRange())
        }
    }
}
#elseif canImport(UIKit)
import UIKit

extension UITextView {
    func adoptSelection(_ range: NSRange) {
        let clamped = Normalizer.clamp(range, to: textStorage.length)
        guard clamped != selectedRange else { return }
        selectedRange = clamped
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.scrollRangeToVisible(self.selectedRange)
        }
    }
}
#endif
