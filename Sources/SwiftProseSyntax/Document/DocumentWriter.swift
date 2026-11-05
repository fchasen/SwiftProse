import Foundation

public protocol DocumentWriter {
    func write(_ document: EditorDocument) -> String
}
