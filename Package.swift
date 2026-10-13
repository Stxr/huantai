// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Huantai",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ht", targets: ["ht"]),
        .executable(name: "HuantaiApp", targets: ["HuantaiApp"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "HuantaiCore", dependencies: ["CSQLite"]),
        .target(name: "HuantaiWeb", dependencies: ["HuantaiCore"]),
        .target(name: "HuantaiFeishu", dependencies: ["HuantaiCore"]),
        .executableTarget(name: "ht", dependencies: ["HuantaiCore", "HuantaiFeishu"]),
        .executableTarget(
            name: "HuantaiApp", dependencies: ["HuantaiCore", "HuantaiWeb", "HuantaiFeishu"],
            exclude: ["Resources"]),
        .testTarget(name: "HuantaiFeishuTests", dependencies: ["HuantaiFeishu", "HuantaiCore"]),
        .testTarget(name: "HuantaiCoreTests", dependencies: ["HuantaiCore", "CSQLite"]),
        .testTarget(name: "HuantaiWebTests", dependencies: ["HuantaiWeb", "HuantaiCore"]),
        .testTarget(name: "HuantaiAppTests", dependencies: ["HuantaiApp", "HuantaiCore", "HuantaiFeishu"]),
    ],
    swiftLanguageModes: [.v5]
)
