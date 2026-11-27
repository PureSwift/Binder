// swift-tools-version: 6.3
import PackageDescription
import class Foundation.ProcessInfo

// force building as dynamic library
let dynamicLibrary = ProcessInfo.processInfo.environment["SWIFT_BUILD_DYNAMIC_LIBRARY"] != nil
let libraryType: PackageDescription.Product.Library.LibraryType? = dynamicLibrary ? .dynamic : nil

let package = Package(
    name: "Binder",
    platforms: [
        // Raised for Synchronization.Mutex, which the serving loop and the
        // object registries use and which is macOS 15 / iOS 18 / watchOS 11 /
        // tvOS 18 or newer. These are the Darwin mocking-build minimums; the
        // real target is Linux and Android, where the version gate does not
        // apply.
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v11),
        .tvOS(.v18),
    ],
    products: [
        .library(
            name: "Binder",
            type: libraryType,
            targets: ["Binder"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-system",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/PureSwift/Socket",
            branch: "main"
        )
    ],
    targets: [
        .target(
            name: "Binder",
            dependencies: [
                "CBinder",
                .product(
                    name: "SystemPackage",
                    package: "swift-system"
                ),
                .product(
                    name: "Socket",
                    package: "Socket"
                )
            ],
            swiftSettings: [
                .define("ENABLE_MOCKING", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "CBinder",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "BinderTests",
            dependencies: ["Binder"],
            swiftSettings: [
                .define("ENABLE_MOCKING", .when(platforms: [.macOS]))
            ]
        )
    ]
)
