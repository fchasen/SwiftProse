import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public protocol Command {
    var id: String { get }

    func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool

    func transaction(
        storage: NSTextStorage,
        selection: NSRange,
        env: StepEnvironment
    ) -> Transaction?
}

public final class CommandRegistry {
    private var commands: [String: Command] = [:]

    public init() {}

    public func register(_ command: Command) {
        commands[command.id] = command
    }

    public func command(for action: EditorAction) -> Command? {
        commands[action.stableID]
    }

    public func canExecute(_ action: EditorAction, storage: NSAttributedString, selection: NSRange) -> Bool {
        command(for: action)?.canExecute(storage: storage, selection: selection) ?? false
    }
}

/// Run `commands` in order; first one that produces a non-nil transaction
/// wins. Mirrors PM's `chainCommands`.
public func chainCommands(_ commands: [Command]) -> Command {
    ChainedCommand(commands: commands)
}

private struct ChainedCommand: Command {
    let commands: [Command]
    var id: String { "chain(" + commands.map(\.id).joined(separator: ",") + ")" }

    func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        commands.contains { $0.canExecute(storage: storage, selection: selection) }
    }

    func transaction(
        storage: NSTextStorage,
        selection: NSRange,
        env: StepEnvironment
    ) -> Transaction? {
        for command in commands {
            if let tx = command.transaction(storage: storage, selection: selection, env: env) {
                return tx
            }
        }
        return nil
    }
}
