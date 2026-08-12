// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MailCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MailCore", targets: ["MailCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "MailCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MailCoreTests",
            dependencies: ["MailCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
