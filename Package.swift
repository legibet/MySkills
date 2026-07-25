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
        .package(url: "https://github.com/gonzalezreal/MarkdownUI.git", from: "2.4.1"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")
    ],
    targets: [
        .executableTarget(
            name: "MySkills",
            dependencies: [
                .product(name: "MarkdownUI", package: "MarkdownUI"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/MySkillsApp",
            )
    ],
    )
