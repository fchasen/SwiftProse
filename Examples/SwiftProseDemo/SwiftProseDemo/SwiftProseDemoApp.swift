import SwiftUI
import Foundation
#if os(macOS)
import AppKit
#endif

@main
struct SwiftProseDemoApp: App {
    /// Under test — or with `--harness` — the document scene is suppressed
    /// and the harness window comes up instead: one deterministic window,
    /// no untitled document, no restoration race.
    ///
    /// `SceneBuilder` has no `buildEither`, so the choice is made with
    /// launch behavior rather than an `if`.
    private let harnessed = HarnessLaunch.isActive
    /// A directly-launched executable never gets its `WindowGroup`
    /// presented; `HarnessAppDelegate` builds the window instead, and the
    /// scene stays suppressed so there is only ever one editor.
    private let commandLine = HarnessLaunch.isCommandLine

    init() {
        guard HarnessLaunch.isActive else { return }
        // Two things would otherwise stall a headless run forever, both as
        // a modal put up before `applicationDidFinishLaunching`:
        // the saved-state restore prompt, and — after the fuzzer has found
        // a crash — "the application quit unexpectedly, reopen windows?".
        // Registering here works because the App's initializer runs before
        // `NSApplication.run` processes the open AppleEvent.
        UserDefaults.standard.register(defaults: [
            "ApplePersistenceIgnoreState": true,
            "NSQuitAlwaysKeepsWindows": false,
            // A crash is the shrinker's signal, not something to report.
            "NSApplicationCrashOnExceptions": true
        ])
    }

#if os(macOS)
    @NSApplicationDelegateAdaptor(HarnessAppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            ContentView(document: file.$document)
        }
        .defaultLaunchBehavior(harnessed ? .suppressed : .automatic)

        WindowGroup("Harness") {
            HarnessView()
        }
        .defaultLaunchBehavior(harnessed && !commandLine ? .presented : .suppressed)
    }
}

#if os(macOS)
/// Only does anything under `--harness`: hosts one `HarnessView` in a real
/// `NSWindow` so the CLI has an editor to drive.
final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard HarnessLaunch.isCommandLine else { return }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwiftProse harness"
        window.contentView = NSHostingView(rootView: HarnessView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        HarnessLaunch.isCommandLine
    }
}
#endif
