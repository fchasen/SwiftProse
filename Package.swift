// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MarginaliaEditor",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0")
    ],
    products: [
        .library(name: "MarginaliaEditor", targets: ["MarginaliaEditor"]),
        .library(name: "MarginaliaSyntax", targets: ["MarginaliaSyntax"])
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.10.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.5.3")
    ],
    targets: [
        .target(
            name: "TreeSitterRemarkup",
            path: "Vendor/tree-sitter-remarkup",
            exclude: [
                "grammar.js",
                "src/grammar.json",
                "src/node-types.json",
            ],
            sources: ["src/parser.c"],
            resources: [.copy("queries")],
            publicHeadersPath: "bindings/swift/TreeSitterRemarkup",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "MarginaliaSyntax",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                "TreeSitterRemarkup",
            ]
        ),
        .target(
            name: "MarginaliaRendering",
            dependencies: ["MarginaliaSyntax"]
        ),
        .target(
            name: "MarginaliaView",
            dependencies: ["MarginaliaSyntax", "MarginaliaRendering"]
        ),
        .target(
            name: "MarginaliaEditor",
            dependencies: ["MarginaliaSyntax", "MarginaliaRendering", "MarginaliaView"]
        ),
        .testTarget(
            name: "MarginaliaSyntaxTests",
            dependencies: ["MarginaliaSyntax"]
        ),
        .testTarget(
            name: "MarginaliaViewTests",
            dependencies: ["MarginaliaView", "MarginaliaSyntax"]
        ),
        .testTarget(
            name: "MarginaliaEditorTests",
            dependencies: ["MarginaliaEditor", "MarginaliaView", "MarginaliaSyntax"]
        )
    ]
)
