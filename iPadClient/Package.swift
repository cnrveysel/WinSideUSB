// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinSideUSBClient",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "WinSideUSBClient", targets: ["WinSideUSBClient"])
    ],
    targets: [
        .target(name: "WinSideUSBClient")
    ],
    swiftLanguageModes: [.v5]
)
