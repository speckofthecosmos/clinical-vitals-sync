// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClinicalMapper",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ClinicalMapper", targets: ["ClinicalMapper"])],
    targets: [
        .target(name: "ClinicalMapper"),
        .testTarget(name: "ClinicalMapperTests", dependencies: ["ClinicalMapper"]),
    ]
)
