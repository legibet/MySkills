// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MySkills",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MySkills", targets: ["MySkills"])
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/MarkdownUI.git", from: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "MySkills",
            dependencies: [
                .product(name: "MarkdownUI", package: "MarkdownUI")
            ],
            path: "Sources/MySkillsApp",
        )
    ],
)
