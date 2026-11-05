import SwiftProseSyntax
import SwiftProseRendering
import SwiftProseView
import Foundation
import Observation

@Observable
final class EditorHosting {
    struct ToolbarState: Equatable {
        var active: Set<String> = []
        var disabled: Set<String> = []
    }

    private(set) var toolbarState = ToolbarState()
    private(set) var selection = NSRange(location: 0, length: 0)

    @ObservationIgnored private(set) var controller: EditorController?
    @ObservationIgnored private(set) var sourceController: SourceEditorController?
    @ObservationIgnored private(set) var handle: EditorHandle?
    @ObservationIgnored private var observerTokens: [EditorController.ObserverToken] = []
    @ObservationIgnored private var sourceTokens: [SourceEditorController.ObserverToken] = []
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    @ObservationIgnored var trackedActions: [EditorAction] = []
    @ObservationIgnored var tracksSelection = false
    @ObservationIgnored private(set) var mode: EditorMode = .rich

    init() {}

    deinit {
        focusTask?.cancel()
        if let controller {
            for token in observerTokens { controller.removeObserver(token) }
        }
        if let sourceController {
            for token in sourceTokens { sourceController.removeObserver(token) }
        }
    }

    @discardableResult
    func ensureController(
        markdown: String,
        theme: ProseTheme,
        inlineContentRules: [InlineContentRule],
        inlineContentProvider: ProseInlineContentProvider?,
        codeBlockHighlighter: CodeBlockHighlighter? = nil,
        allowsCheckboxToggle: Bool,
        mode: EditorMode = .rich
    ) -> EditorController {
        if let controller { return controller }
        let created = EditorController(
            markdown: markdown,
            theme: theme,
            inlineContentRules: inlineContentRules,
            inlineContentProvider: inlineContentProvider,
            codeBlockHighlighter: codeBlockHighlighter
        )
        created.allowsCheckboxToggle = allowsCheckboxToggle
        controller = created
        observerTokens = [
            created.addOnSelectionChanged { [weak self] range in self?.selectionDidChange(range) },
            created.addOnDocumentChange { [weak self] _ in self?.scheduleToolbarRefresh() }
        ]
        let source = SourceEditorController(
            text: mode == .source ? markdown : "",
            theme: theme,
            codeBlockHighlighter: codeBlockHighlighter
        )
        sourceController = source
        sourceTokens = [
            source.addOnSelectionChanged { [weak self] range in self?.selectionDidChange(range) },
            source.addOnTextChange { [weak self] _ in self?.scheduleToolbarRefresh() }
        ]
        self.mode = mode
        handle = EditorHandle(richController: created, sourceController: source, mode: mode)
        scheduleToolbarRefresh()
        return created
    }

    private func selectionDidChange(_ range: NSRange) {
        scheduleToolbarRefresh()
        if tracksSelection, range != selection { selection = range }
    }

    func applyInlineContent(rules: [InlineContentRule], provider: ProseInlineContentProvider?) {
        guard let controller else { return }
        let sameRules = controller.inlineContentRules.map(\.id) == rules.map(\.id)
        let sameProvider = (controller.inlineContentProvider == nil) == (provider == nil)
        guard !sameRules || !sameProvider else { return }
        controller.setInlineContent(rules: rules, provider: provider)
    }

    func apply(theme: ProseTheme) {
        controller?.theme = theme
        sourceController?.theme = theme
    }

    func apply(codeBlockHighlighter: CodeBlockHighlighter?) {
        controller?.setCodeBlockHighlighter(codeBlockHighlighter)
        sourceController?.setCodeBlockHighlighter(codeBlockHighlighter)
    }

    func setMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        handle?.synchronize(for: newMode)
        mode = newMode
        handle?.mode = newMode
        scheduleToolbarRefresh()
    }

    func requestFocus() {
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                guard let self, !Task.isCancelled else { return }
                if self.handle?.focus() == true { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func perform(_ action: EditorAction) {
        handle?.perform(action)
    }

    func scheduleToolbarRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshToolbarState()
        }
    }

    func refreshToolbarState() {
        let next: ToolbarState
        switch mode {
        case .rich:
            guard let controller else { return }
            next = ToolbarState(
                active: controller.activeActionIDs(),
                disabled: Set(trackedActions.filter { !controller.canPerform($0) }.map(\.stableID))
            )
        case .source:
            guard let sourceController else { return }
            let states = sourceController.actionStates(for: trackedActions)
            next = ToolbarState(active: states.active, disabled: states.disabled)
        }
        if next != toolbarState { toolbarState = next }
    }

    func isActive(_ action: EditorAction) -> Bool {
        toolbarState.active.contains(action.stableID)
    }

    func canPerform(_ action: EditorAction) -> Bool {
        !toolbarState.disabled.contains(action.stableID)
    }
}
