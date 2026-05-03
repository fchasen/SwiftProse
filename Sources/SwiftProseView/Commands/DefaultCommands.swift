import Foundation

extension CommandRegistry {
    public static func makeDefault() -> CommandRegistry {
        let registry = CommandRegistry()
        registry.register(ToggleBoldCommand())
        registry.register(ToggleItalicCommand())
        registry.register(ToggleStrikethroughCommand())
        registry.register(ToggleCodeSpanCommand())
        for level in 0...6 {
            registry.register(SetHeadingCommand(level: level))
        }
        registry.register(ToggleUnorderedListCommand())
        registry.register(ToggleOrderedListCommand())
        registry.register(ToggleTaskListCommand())
        registry.register(ToggleBlockquoteCommand())
        registry.register(ToggleCodeBlockCommand())
        registry.register(InsertHorizontalRuleCommand())
        registry.register(IndentCommand())
        registry.register(OutdentCommand())
        return registry
    }
}
