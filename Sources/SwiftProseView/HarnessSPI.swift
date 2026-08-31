import Foundation

/// Seams the out-of-package editing harness in `Examples/SwiftProseDemo`
/// drives. `@_spi(Harness)` keeps them off the public API surface while
/// letting a target that isn't a package test reach them — the harness
/// lives in the demo app, which can't `@testable import`.
extension EditorController {

    /// Whether a platform edit is queued but not yet closed. The drain is
    /// deferred to the next tick while a host text view is attached.
    @_spi(Harness)
    public var hasPendingEnvelopes: Bool { !pendingEnvelopes.isEmpty }

    /// Close every queued platform envelope now.
    @_spi(Harness)
    public func drainPendingEnvelopesForHarness() {
        drainPendingEnvelopes()
    }

    /// Turn the DEBUG post-edit spec assertion off so a fuzz run reports
    /// many oracle failures instead of trapping on the first.
    @_spi(Harness)
    public var harnessAssertsOnDiagnostics: Bool {
        get { assertsOnDiagnostics }
        set { assertsOnDiagnostics = newValue }
    }

    /// Fires with `String(describing:)` of the class every closed platform
    /// envelope was assigned — the fuzzer logs it as coverage feedback.
    @_spi(Harness)
    public var harnessClassificationProbe: ((String) -> Void)? {
        get { harnessProbeBox }
        set {
            harnessProbeBox = newValue
            guard let newValue else {
                classificationProbe = nil
                return
            }
            classificationProbe = { newValue(String(describing: $0)) }
        }
    }
}
