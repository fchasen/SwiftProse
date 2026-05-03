import SwiftUI
import SwiftProse

struct ContentView: View {
    @State private var text: String = "# Hello\n\nType into me.\n"
    @State private var controller: EditorController?
    @State private var lastExport: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlBar
            Divider()
            SwiftProseEditor(text: $text)
                .configuration(.init(
                    toolbar: SwiftProseEditor.Configuration.defaultToolbar,
                    statusItems: [.words, .characters, .cursor]
                ))
                .onProseControllerReady { controller = $0 }
                .accessibilityIdentifier("prose-editor")
                .padding(8)
            if !lastExport.isEmpty {
                Divider()
                TextEditor(text: .constant(lastExport))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxHeight: 160)
                    .accessibilityIdentifier("export-output")
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button("Load PM JSON") { loadFixtureJSON() }
                .accessibilityIdentifier("load-pm")
            Button("Export PM JSON") { exportJSON() }
                .accessibilityIdentifier("export-pm")
                .disabled(controller == nil)
            Spacer()
        }
        .padding(8)
    }

    private func loadFixtureJSON() {
        guard let controller else { return }
        let fixture = """
        {"type":"doc","content":[
          {"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Loaded title"}]},
          {"type":"paragraph","content":[{"type":"text","text":"Loaded body."}]}
        ]}
        """
        try? controller.loadProseMirrorJSON(fixture)
        text = controller.markdown()
    }

    private func exportJSON() {
        guard let controller else { return }
        guard let data = try? controller.exportProseMirrorJSON(),
              let s = String(data: data, encoding: .utf8) else { return }
        lastExport = s
    }
}

#Preview {
    ContentView()
}
