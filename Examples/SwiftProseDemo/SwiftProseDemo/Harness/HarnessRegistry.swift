import Foundation
import SwiftUI
@_spi(Harness) import SwiftProse

/// The rendezvous between the app's editor and whatever drives it — a
/// hosted test, the fuzz CLI, or the inspector's Run button.
///
/// `HarnessView` publishes the controller here as soon as
/// `onProseControllerReady` fires; `waitForEditor()` polls for it.
@MainActor
final class HarnessRegistry: ObservableObject {
    static let shared = HarnessRegistry()

    private init() {}

    @Published var controller: EditorController?
    /// Mirrors `controller.markdown()` for the inspector and for XCUITests,
    /// which can only read accessibility values.
    @Published var markdownMirror: String = ""
    /// Latest status line the runner wants on screen.
    @Published var status: String = "idle"
    /// Op index a live run has reached, for the inspector's stepper.
    @Published var progress: Int = 0
    /// Set by `--harness replay --stop-at N`: the run pauses here and the
    /// window stays up.
    @Published var paused: Bool = false

    /// Edit routes seen since the last reset, as coverage feedback.
    var classCoverage: [String: Int] = [:]

    private var documentToken: EditorController.ObserverToken?

    func attach(_ controller: EditorController) {
        self.controller = controller
        controller.harnessEditRouteProbe = { [weak self] route in
            self?.classCoverage[route, default: 0] += 1
        }
        documentToken = controller.addOnDocumentChange { [weak self] _ in
            guard let self, let controller = self.controller else { return }
            self.markdownMirror = controller.markdown()
        }
        markdownMirror = controller.markdown()
    }

    func detach() {
        guard let controller else { return }
        if let documentToken { controller.removeObserver(documentToken) }
        controller.harnessEditRouteProbe = nil
        self.controller = nil
    }

    func clearCollected() {
        classCoverage.removeAll()
    }
}
