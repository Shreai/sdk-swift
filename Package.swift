// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShreAI",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ShreAI", targets: ["ShreAI"])
    ],
    targets: [
        .target(
            name: "ShreAI",
            path: "Sources/ShreAI",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        )
    ]
)
