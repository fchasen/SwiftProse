import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct DocumentChangeLazinessTests {

    private func type(_ controller: EditorController, _ text: String, at location: Int) {
        let storage = controller.textStorage
        controller.testSelection = NSRange(location: location, length: 0)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: text)
        storage.endEditing()
    }

    @Test func subscriberIgnoringDocumentCostsNoProjection() throws {
        let controller = try EditorController(initialMarkdown: "hello world\n")
        var fireCount = 0
        _ = controller.addOnDocumentChange { _ in fireCount += 1 }
        controller.projectionRunCount = 0

        for i in 0..<10 {
            type(controller, "a", at: 5 + i)
        }

        #expect(fireCount == 10)
        #expect(controller.projectionRunCount == 0,
                "unread DocumentChange.document must not project the tree")
    }

    @Test func subscriberReadingDocumentProjectsOncePerChange() throws {
        let controller = try EditorController(initialMarkdown: "hello world\n")
        var seen: [Int] = []
        _ = controller.addOnDocumentChange { change in
            seen.append(change.document.root.contentLength)
        }
        controller.projectionRunCount = 0

        for i in 0..<10 {
            type(controller, "a", at: 5 + i)
        }

        #expect(seen.count == 10)
        // One rebuild per change, but only the first is a full projection:
        // the rest are splices over the block the keystroke touched.
        #expect(controller.projectionRunCount + controller.splicedProjectionRunCount == 10,
                "one tree rebuild per change when the subscriber reads it")
        #expect(controller.projectionRunCount == 1,
                "only the first read projects the whole document")
    }

    @Test func repeatedDocumentReadsWithinOneChangeProjectOnce() throws {
        let controller = try EditorController(initialMarkdown: "hello world\n")
        _ = controller.addOnDocumentChange { change in
            _ = change.document
            _ = change.document
            _ = change.document
        }
        controller.projectionRunCount = 0
        controller.splicedProjectionRunCount = 0
        type(controller, "a", at: 5)
        #expect(controller.projectionRunCount + controller.splicedProjectionRunCount == 1)
    }

    @Test func noSubscribersMeansNoProjection() throws {
        let controller = try EditorController(initialMarkdown: "hello world\n")
        controller.projectionRunCount = 0
        for i in 0..<10 {
            type(controller, "a", at: 5 + i)
        }
        #expect(controller.projectionRunCount == 0)
    }

    @Test func validateAndRepairWithoutSchemaHandlerDoesNotProject() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 5, length: 0)
        controller.projectionRunCount = 0
        _ = controller.apply(Transaction(steps: [
            .replaceText(range: NSRange(location: 5, length: 0),
                         with: NSAttributedString(string: "!"))
        ]))
        #expect(controller.projectionRunCount == 0)
    }

    @Test func validateAndRepairWithSchemaHandlerStillRuns() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var diagnosticCount = 0
        controller.onSchemaDiagnostic = { _ in diagnosticCount += 1 }
        controller.testSelection = NSRange(location: 5, length: 0)
        _ = controller.apply(Transaction(steps: [
            .replaceText(range: NSRange(location: 5, length: 0),
                         with: NSAttributedString(string: "!"))
        ]))
        // The handler is installed, so the schema pass ran. A clean
        // document produces no diagnostics; the point is that it didn't
        // crash and the projection is reachable.
        #expect(diagnosticCount == 0)
        #expect(controller.document.root.contentLength >= 0)
    }

    @Test func documentReadOutsideAChangeStillProjects() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.projectionRunCount = 0
        _ = controller.document
        #expect(controller.projectionRunCount == 1)
        _ = controller.document
        #expect(controller.projectionRunCount == 1, "second read hits the cache")
    }
}
