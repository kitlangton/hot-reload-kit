// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "HotReloadKit",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "HotReloadUI", targets: ["HotReloadUI"]),
    .executable(name: "hotreload", targets: ["HotReloadCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.2"),
  ],
  targets: [
    .target(name: "HotReloadProtocol"),
    .target(
      name: "HotReloadCore",
      dependencies: [
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "HotReloadRuntime",
      dependencies: ["HotReloadProtocol"]
    ),
    .macro(
      name: "HotReloadMacros",
      dependencies: [
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "HotReloadUI",
      dependencies: ["HotReloadMacros", "HotReloadRuntime"]
    ),
    .executableTarget(
      name: "HotReloadCLI",
      dependencies: [
        "HotReloadCore",
        "HotReloadProtocol",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "HotReloadCoreTests",
      dependencies: ["HotReloadCore"]
    ),
    .testTarget(
      name: "HotReloadRuntimeTests",
      dependencies: ["HotReloadRuntime"]
    ),
    .testTarget(
      name: "HotReloadMacrosTests",
      dependencies: [
        "HotReloadMacros",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
      ]
    ),
  ]
)
