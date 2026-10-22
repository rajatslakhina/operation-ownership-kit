// swift-tools-version:6.0
import PackageDescription

// Library-only package: no executable product, no app target. The runnable
// demo lives in a separate repository (operation-ownership-demo-app) that
// consumes this package as a version-pinned remote dependency.
let package = Package(
    name: "OperationOwnership",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "OperationOwnership", targets: ["OperationOwnership"]),
        .library(name: "OperationOwnershipUI", targets: ["OperationOwnershipUI"]),
    ],
    targets: [
        .target(name: "OperationOwnership"),
        .target(name: "OperationOwnershipUI", dependencies: ["OperationOwnership"]),
        .testTarget(name: "OperationOwnershipTests", dependencies: ["OperationOwnership"]),
    ],
    swiftLanguageModes: [.v6]
)
