// swift-tools-version: 5.10
import PackageDescription
import Foundation

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
    targets: [
        .target(name: "SwiftProseSyntax"),
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
        .target(
            name: "SwiftProseTestSupport",
            dependencies: ["SwiftProseSyntax", "SwiftProseView"],
            path: "Tests/Support"
        ),
        .testTarget(
            name: "SwiftProseSyntaxTests",
            dependencies: ["SwiftProseSyntax", "SwiftProseTestSupport"]
        ),
        .testTarget(
            name: "SwiftProseViewTests",
            dependencies: ["SwiftProseView", "SwiftProseRendering", "SwiftProseSyntax", "SwiftProseTestSupport"],
            exclude: ["Benchmarks/BASELINE.md"]
        ),
        .testTarget(
            name: "SwiftProseTests",
            dependencies: ["SwiftProse", "SwiftProseView", "SwiftProseSyntax", "SwiftProseTestSupport"]
        )
    ]
)

// DocC is opt-in so apps that depend on SwiftProse don't resolve a plugin
// they will never build with. Generate the reference with:
//
//   SWIFTPROSE_DOCS=1 swift package generate-documentation
//
// Xcode's Product > Build Documentation needs none of this.
if ProcessInfo.processInfo.environment["SWIFTPROSE_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")
    )
}
