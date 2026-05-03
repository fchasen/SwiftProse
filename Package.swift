// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftProse",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0")
    ],
    products: [
        .library(name: "SwiftProse", targets: ["SwiftProse"]),
        .library(name: "SwiftProseSyntax", targets: ["SwiftProseSyntax"])
    ],
    dependencies: [
        .package(name: "SwiftTreeSitter", url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.10.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.5.3")
    ],
    targets: [
        .target(
            name: "SwiftProseSyntax",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ]
        ),
        .target(
            name: "SwiftProseRendering",
            dependencies: ["SwiftProseSyntax"]
        ),
        .target(
            name: "SwiftProseView",
            dependencies: ["SwiftProseSyntax", "SwiftProseRendering"]
        ),
        .target(
            name: "SwiftProse",
            dependencies: ["SwiftProseSyntax", "SwiftProseRendering", "SwiftProseView"]
        ),
        .testTarget(
            name: "SwiftProseSyntaxTests",
            dependencies: ["SwiftProseSyntax"]
        ),
        .testTarget(
            name: "SwiftProseViewTests",
            dependencies: ["SwiftProseView", "SwiftProseSyntax"]
        ),
        .testTarget(
            name: "SwiftProseTests",
            dependencies: ["SwiftProse", "SwiftProseView", "SwiftProseSyntax"]
        )
    ]
)
