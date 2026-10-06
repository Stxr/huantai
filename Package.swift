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
        .executableTarget(name: "ht", dependencies: ["HuantaiCore"]),
        .executableTarget(name: "HuantaiApp", dependencies: ["HuantaiCore", "HuantaiWeb"]),
        .testTarget(name: "HuantaiCoreTests", dependencies: ["HuantaiCore", "CSQLite"]),
        .testTarget(name: "HuantaiWebTests", dependencies: ["HuantaiWeb", "HuantaiCore"]),
        .testTarget(name: "HuantaiAppTests", dependencies: ["HuantaiApp", "HuantaiCore"]),
    ],
    swiftLanguageModes: [.v5]
)
