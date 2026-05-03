import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite struct ValidationTests {

    private func env() throws -> StepEnvironment {
        let compiler = try MarkdownAttributedCompiler()
        return StepEnvironment(
            compiler: compiler,
            serializer: AttributedMarkdownSerializer(),
            theme: .default,
            dialect: .commonMark,
            mode: .rich
        )
    }

    @Test func detectsMissingSpec() throws {
        let env = try env()
        let storage = NSTextStorage(attributedString: env.compiler.compile("hello\n", dialect: .commonMark, mode: .rich, theme: .default))
        // Manually corrupt: strip the spec from one char.
        storage.removeAttribute(.marginaliaBlockSpec, range: NSRange(location: 1, length: 1))
        let diagnostics = SpecValidator.validate(in: storage, range: NSRange(location: 0, length: storage.length))
        #expect(diagnostics.contains { if case .missingSpec = $0.issue { return true } else { return false } })
    }

    @Test func detectsInconsistentSpecAcrossParagraph() throws {
        let env = try env()
        let storage = NSTextStorage(attributedString: env.compiler.compile("hello\n", dialect: .commonMark, mode: .rich, theme: .default))
        // Set a different spec on one char.
        storage.addAttribute(.marginaliaBlockSpec,
                             value: BlockSpecBox(BlockSpec(kind: .heading(level: 1))),
                             range: NSRange(location: 0, length: 1))
        let diagnostics = SpecValidator.validate(in: storage, range: NSRange(location: 0, length: storage.length))
        #expect(diagnostics.contains { if case .inconsistentSpec = $0.issue { return true } else { return false } })
    }

    @Test func cleanStorageHasNoDiagnostics() throws {
        let env = try env()
        let storage = NSTextStorage(attributedString: env.compiler.compile("# Heading\n- bullet\n> quote\n", dialect: .commonMark, mode: .rich, theme: .default))
        let diagnostics = SpecValidator.validate(in: storage, range: NSRange(location: 0, length: storage.length))
        #expect(diagnostics.isEmpty, "compiled storage should be valid; got \(diagnostics)")
    }

    @Test func repairFillsMissingSpecFromLine() throws {
        let env = try env()
        let storage = NSTextStorage(attributedString: env.compiler.compile("hello world\n", dialect: .commonMark, mode: .rich, theme: .default))
        storage.removeAttribute(.marginaliaBlockSpec, range: NSRange(location: 0, length: 5))
        SpecValidator.repair(in: storage, range: NSRange(location: 0, length: storage.length))
        let diagnostics = SpecValidator.validate(in: storage, range: NSRange(location: 0, length: storage.length))
        #expect(diagnostics.isEmpty, "repair should restore consistency, got \(diagnostics)")
    }

    @Test func repairResolvesInconsistentSpec() throws {
        let env = try env()
        let storage = NSTextStorage(attributedString: env.compiler.compile("hello world\n", dialect: .commonMark, mode: .rich, theme: .default))
        storage.addAttribute(.marginaliaBlockSpec,
                             value: BlockSpecBox(BlockSpec(kind: .heading(level: 2))),
                             range: NSRange(location: 0, length: 1))
        SpecValidator.repair(in: storage, range: NSRange(location: 0, length: storage.length))
        let diagnostics = SpecValidator.validate(in: storage, range: NSRange(location: 0, length: storage.length))
        #expect(diagnostics.isEmpty, "repair should resolve inconsistency, got \(diagnostics)")
    }

    @Test func transactionApplyLeavesValidStorage() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        // setSpec re-renders the entire line so any pre-existing corruption
        // in that range is wiped out — the post-state should be valid.
        controller.textStorage.removeAttribute(.marginaliaBlockSpec, range: NSRange(location: 0, length: 1))
        let lineRange = NSRange(location: 0, length: controller.textStorage.length)
        controller.apply(Transaction(steps: [
            .setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 1)))
        ]))
        let post = SpecValidator.validate(in: controller.textStorage, range: NSRange(location: 0, length: controller.textStorage.length))
        #expect(post.isEmpty, "transaction-applied storage should be valid")
    }

    @Test func validateOnZeroLengthRangeStaysInScope() {
        // forEachLine must not walk the entire storage when called with
        // a length-0 range; otherwise an unrelated paragraph's drift
        // would surface in a transaction that didn't touch it.
        let storage = NSMutableAttributedString(string: "alpha\nbeta\n")
        storage.setBlockSpec(.paragraph, in: NSRange(location: 0, length: 6))
        // Leave line 1 (chars 6..11) without any spec — that's a
        // pre-existing condition the validator should NOT report when
        // validating a zero-length point at line 0's start.
        let diagnostics = SpecValidator.validate(in: storage, range: NSRange(location: 0, length: 0))
        let touchedLine1 = diagnostics.contains { diag in
            switch diag.issue {
            case .missingSpec(let at): return at >= 6
            default: return false
            }
        }
        #expect(!touchedLine1,
                "zero-length validation must not leak into other paragraphs; got \(diagnostics)")
    }
}
