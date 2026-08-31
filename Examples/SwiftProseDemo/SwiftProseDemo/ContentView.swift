import SwiftUI
import SwiftProse

struct ContentView: View {
    @Binding var document: MarkdownDocument
    @State private var controller: EditorController?
    private static let codeHighlighter: CodeBlockHighlighter? = DemoCodeHighlighter.make()

    var body: some View {
        SwiftProseEditor(text: $document.text)
            .configuration(.init(
                toolbar: [],
                statusItems: [],
                sizing: .fillContainer
            ))
            .codeBlockHighlighter(Self.codeHighlighter)
            .onProseControllerReady { controller = $0 }
            .accessibilityIdentifier("prose-editor")
            .toolbar { FormattingToolbar(controller: controller) }
    }
}

#Preview {
    ContentView(document: .constant(MarkdownDocument()))
}
