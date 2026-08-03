// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let env = ProcessInfo.processInfo.environment
let fm = FileManager.default

var candidatePrefixes: [String] = []
if let custom = env["HOMEBREW_PREFIX"], !custom.isEmpty { candidatePrefixes.append(custom) }
if let customPurple = env["PURPLE_PREFIX"], !customPurple.isEmpty { candidatePrefixes.append(customPurple) }
candidatePrefixes.append(contentsOf: ["/opt/homebrew", "/usr/local", "/usr"])

var includeFlags: [String] = []
var libFlags: [String] = []

for prefix in candidatePrefixes {
    let subIncludes = [
        "\(prefix)/include/libpurple",
        "\(prefix)/include/glib-2.0",
        "\(prefix)/lib/glib-2.0/include",
        "\(prefix)/include/json-glib-1.0",
        "\(prefix)/opt/gettext/include"
    ]
    for inc in subIncludes {
        if fm.fileExists(atPath: inc) && !includeFlags.contains(inc) {
            includeFlags.append(inc)
        }
    }
    
    let subLibs = [
        "\(prefix)/lib",
        "\(prefix)/opt/gettext/lib"
    ]
    for lib in subLibs {
        if fm.fileExists(atPath: lib) && !libFlags.contains(lib) {
            libFlags.append(lib)
        }
    }
}

// Fallbacks if nothing detected on disk during manifest parse
if includeFlags.isEmpty {
    includeFlags = [
        "/opt/homebrew/include/libpurple",
        "/opt/homebrew/include/glib-2.0",
        "/opt/homebrew/lib/glib-2.0/include",
        "/opt/homebrew/include/json-glib-1.0",
        "/opt/homebrew/opt/gettext/include",
        "/usr/local/include/libpurple",
        "/usr/local/include/glib-2.0",
        "/usr/local/lib/glib-2.0/include",
        "/usr/local/include/json-glib-1.0",
        "/usr/local/opt/gettext/include"
    ]
}

if libFlags.isEmpty {
    libFlags = [
        "/opt/homebrew/lib",
        "/opt/homebrew/opt/gettext/lib",
        "/usr/local/lib",
        "/usr/local/opt/gettext/lib"
    ]
}

let cHeaderFlags = includeFlags.flatMap { ["-I", $0] }
let linkerSearchFlags = libFlags.flatMap { ["-L", $0] } + ["-lpurple", "-lglib-2.0", "-ljson-glib-1.0", "-lintl", "-Xlinker", "-w"]

let package = Package(
    name: "AdiumSwift",
    platforms: [.macOS(.v14)],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CLibpurple",
            cSettings: [
                .unsafeFlags(cHeaderFlags)
            ],
            linkerSettings: [
                .unsafeFlags(linkerSearchFlags)
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

