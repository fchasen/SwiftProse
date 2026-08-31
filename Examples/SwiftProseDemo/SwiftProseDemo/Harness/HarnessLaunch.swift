import Foundation

/// How the app was launched. Under test — or with `--harness` — the app
/// presents a single deterministic window instead of the `DocumentGroup`,
/// so there is no Cmd-N, no restoration race, and no second window.
enum HarnessLaunch {

    enum Mode: Equatable {
        /// A window with the editor and inspector, waiting for a driver.
        case interactive
        /// `--harness fuzz` — run a fuzz session, then exit.
        case fuzz
        /// `--harness replay` — replay an op log, optionally shrinking.
        case replay
        /// `--harness ui` — the XCUITest surface.
        case ui
    }

    /// Arguments, overridable so the parser is testable.
    static var arguments: [String] = CommandLine.arguments
    static var environment: [String: String] = ProcessInfo.processInfo.environment

    static var isActive: Bool { mode != nil }

    /// True when `--harness` was passed on the command line, as opposed to
    /// an XCTest bundle being injected. A directly-launched executable
    /// never gets its `WindowGroup` presented, so the CLI builds its own
    /// window; under XCTest the scene comes up on its own.
    static var isCommandLine: Bool { arguments.contains("--harness") }

    static var mode: Mode? {
        if let i = arguments.firstIndex(of: "--harness") {
            let next = i + 1 < arguments.count ? arguments[i + 1] : ""
            switch next {
            case "fuzz": return .fuzz
            case "replay": return .replay
            case "ui": return .ui
            default: return .interactive
            }
        }
        // An XCTest bundle injected into this process. Covers both the
        // hosted unit-test bundle and an XCUITest target's app launch.
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        where environment[key] != nil {
            return .interactive
        }
        return nil
    }

    /// `--flag value`
    static func value(_ flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        let next = arguments[i + 1]
        return next.hasPrefix("--") ? nil : next
    }

    static func intValue(_ flag: String) -> Int? { value(flag).flatMap(Int.init) }

    static func has(_ flag: String) -> Bool { arguments.contains(flag) }

    /// Env var read that works from a hosted test bundle: `xcodebuild`
    /// forwards `TEST_RUNNER_`-prefixed variables into the app under test.
    static func env(_ name: String) -> String? {
        environment[name] ?? environment["TEST_RUNNER_" + name]
    }

    static func envInt(_ name: String) -> Int? { env(name).flatMap(Int.init) }

    /// `SWIFTPROSE_TRACE=1` prints each step of a run to stderr. A run that
    /// stops printing has found where it is stuck — which is the only way
    /// to see inside a headless soak.
    static let traceEnabled = env("SWIFTPROSE_TRACE") != nil || env("SWIFTPROSE_TRACE_ORACLES") != nil

    static func trace(_ message: @autoclosure () -> String) {
        guard traceEnabled else { return }
        FileHandle.standardError.write(Data("trace: \(message())\n".utf8))
    }
}
