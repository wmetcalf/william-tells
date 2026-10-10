// swift-tools-version:5.9
import Foundation
import PackageDescription

// Absolute path of this package, for the linker flag that embeds wtqrk-scan's Info.plist.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "QRScannerService",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "App", targets: ["App"]),
        .executable(name: "wtqrk-scan", targets: ["wtqrk-scan"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
    ],
    targets: [
        // Scanner + models. No Vapor: shared by the web service and the sandboxed CLI.
        .target(
            name: "QRScanCore",
            path: "Sources/QRScanCore"
        ),
        // One-shot scanner for running one untrusted image per sandboxed process (blastbox).
        .executableTarget(
            name: "wtqrk-scan",
            dependencies: ["QRScanCore"],
            path: "Sources/wtqrk-scan",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(packageDir)/Sources/wtqrk-scan/Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                "QRScanCore",
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/App"
        ),
        .testTarget(
            name: "QRScanCoreTests",
            dependencies: ["QRScanCore"],
            path: "Tests/QRScanCoreTests"
        ),
    ]
)
