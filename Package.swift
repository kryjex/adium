// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AdiumSwift",
    platforms: [.macOS(.v14)],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CLibpurple",
            cSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/include/libpurple",
                    "-I/opt/homebrew/include/glib-2.0",
                    "-I/opt/homebrew/lib/glib-2.0/include",
                    "-I/opt/homebrew/include/json-glib-1.0",
                    "-I/opt/homebrew/opt/gettext/include"
                ])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-L/opt/homebrew/opt/gettext/lib", "-lpurple", "-lglib-2.0", "-ljson-glib-1.0", "-lintl", "-Xlinker", "-w"])
            ]
        ),
        .executableTarget(
            name: "AdiumSwift",
            dependencies: ["CLibpurple"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AdiumSwiftTests",
            dependencies: ["AdiumSwift"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
