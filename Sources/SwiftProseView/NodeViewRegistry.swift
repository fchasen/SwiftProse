import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A host that vends the platform attachment-view-provider for an
/// isolating-flagged node type. Registered on `EditorController`'s
/// `NodeViewRegistry` at startup; the compiler/editor consult the registry
/// when emitting an isolating node so the host's view replaces the default
/// flat storage projection.
public protocol NodeViewProvider: AnyObject {
    var nodeType: NodeType.Name { get }
    func makeAttachmentViewProvider(
        for path: NodePath,
        theme: ProseTheme,
        dispatch: @escaping (Transaction) -> Void
    ) -> NSTextAttachmentViewProvider
}

/// Registry of view providers keyed by node-type name. Kept on
/// `EditorController` as the parallel of the host-injected
/// `CodeBlockHighlighter` registration. Empty by default — registering a
/// provider opts that node type into the node-view rendering path.
public final class NodeViewRegistry {
    private var providers: [NodeType.Name: NodeViewProvider] = [:]

    public init() {}

    public func register(_ provider: NodeViewProvider) {
        providers[provider.nodeType] = provider
    }

    public func unregister(_ nodeType: NodeType.Name) {
        providers.removeValue(forKey: nodeType)
    }

    public func provider(for nodeType: NodeType.Name) -> NodeViewProvider? {
        providers[nodeType]
    }
}
