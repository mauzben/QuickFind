// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QuickFind",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "QuickFind", targets: ["QuickFind"]),
        .executable(name: "qf", targets: ["qf"]),
    ],
    targets: [
        .target(name: "QuickFindCore"),
        .executableTarget(
            name: "QuickFind",
            dependencies: ["QuickFindCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(name: "qf", dependencies: ["QuickFindCore"]),
    ]
)
