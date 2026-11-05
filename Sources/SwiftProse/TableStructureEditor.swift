import SwiftProseSyntax
import SwiftProseRendering
import SwiftProseView
import Foundation
import SwiftUI

public struct TableStructureEditor: View {
    @State private var model: TableStructureModel
    private let onCancel: () -> Void
    private let onDone: (TableStructureModel) -> Void

    public init(
        model: TableStructureModel,
        onCancel: @escaping () -> Void,
        onDone: @escaping (TableStructureModel) -> Void
    ) {
        self._model = State(initialValue: model)
        self.onCancel = onCancel
        self.onDone = onDone
    }

    public var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle("Edit Table")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDone(model) }
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Table").font(.headline)
            content
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done") { onDone(model) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 440)
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                Stepper("Rows: \(model.rowCount)", value: rowCount, in: 1...200)
                Stepper("Columns: \(model.columnCount)", value: columnCount, in: 1...30)
            }
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        ForEach(Array(model.columns.enumerated()), id: \.element.id) { index, _ in
                            columnControls(index)
                        }
                    }
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { rowIndex, _ in
                        GridRow {
                            rowControls(rowIndex)
                            ForEach(Array(model.columns.enumerated()), id: \.element.id) { columnIndex, column in
                                cell(row: rowIndex, column: columnIndex, alignment: column.alignment)
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
        #if os(iOS)
        .padding()
        #endif
    }

    private var rowCount: Binding<Int> {
        Binding(get: { model.rowCount }, set: { model.setRowCount($0) })
    }

    private var columnCount: Binding<Int> {
        Binding(get: { model.columnCount }, set: { model.setColumnCount($0) })
    }

    private func alignment(for index: Int) -> Binding<SwiftProseSyntax.TableColumnAlignment> {
        Binding(
            get: { model.columns.indices.contains(index) ? model.columns[index].alignment : .none },
            set: { model.setAlignment($0, forColumn: index) }
        )
    }

    private func columnControls(_ index: Int) -> some View {
        VStack(spacing: 4) {
            Picker("Alignment", selection: alignment(for: index)) {
                ForEach(SwiftProseSyntax.TableColumnAlignment.allCases, id: \.self) { alignment in
                    Label(Self.title(alignment), systemImage: Self.symbol(alignment)).tag(alignment)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            HStack(spacing: 2) {
                iconButton("chevron.left", help: "Move column left", disabled: index == 0) {
                    model.moveColumn(from: index, to: index - 1)
                }
                iconButton("plus", help: "Insert column after") {
                    model.insertColumn(at: index + 1)
                }
                iconButton("trash", help: "Delete column", disabled: model.columnCount == 1) {
                    model.deleteColumn(at: index)
                }
                iconButton("chevron.right", help: "Move column right", disabled: index == model.columnCount - 1) {
                    model.moveColumn(from: index, to: index + 1)
                }
            }
        }
        .frame(minWidth: Self.cellWidth)
    }

    private func rowControls(_ index: Int) -> some View {
        HStack(spacing: 2) {
            iconButton("chevron.up", help: "Move row up", disabled: index == 0) {
                model.moveRow(from: index, to: index - 1)
            }
            iconButton("chevron.down", help: "Move row down", disabled: index == model.rowCount - 1) {
                model.moveRow(from: index, to: index + 1)
            }
            iconButton("plus", help: "Insert row below") {
                model.insertRow(at: index + 1)
            }
            iconButton("trash", help: "Delete row", disabled: model.rowCount == 1) {
                model.deleteRow(at: index)
            }
        }
    }

    private func cell(row: Int, column: Int, alignment: SwiftProseSyntax.TableColumnAlignment) -> some View {
        let preview = model.preview(row: row, column: column)
        return Text(preview.isEmpty ? " " : preview)
            .fontWeight(row == 0 ? .semibold : .regular)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(preview.isEmpty ? .secondary : .primary)
            .frame(width: Self.cellWidth, alignment: Self.frameAlignment(alignment))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(row == 0 ? Color.secondary.opacity(0.12) : Color.clear)
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    static let cellWidth: CGFloat = 110

    static func frameAlignment(_ alignment: SwiftProseSyntax.TableColumnAlignment) -> Alignment {
        switch alignment {
        case .none, .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    static func title(_ alignment: SwiftProseSyntax.TableColumnAlignment) -> String {
        switch alignment {
        case .none: return "Default"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    static func symbol(_ alignment: SwiftProseSyntax.TableColumnAlignment) -> String {
        EditorAction.setTableColumnAlignment(alignment).systemImage
    }
}
