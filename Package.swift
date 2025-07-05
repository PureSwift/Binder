// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Binder",
    products: [
        .library(
            name: "Binder",
            targets: ["Binder"]
        )
    ],
    targets: [
        .target(
            name: "Binder",
            dependencies: [
                "CBinder"
            ]
        ),
        .target(
            name: "CBinder",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "BinderTests",
            dependencies: ["Binder"]
        )
    ]
)
