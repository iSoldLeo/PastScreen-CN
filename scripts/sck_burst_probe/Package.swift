// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sck-burst-probe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "sck-burst-probe",
            path: ".",
            exclude: ["README.md"],
            sources: ["main.swift"]
        )
    ]
)
