// swift-tools-version:5.9
import PackageDescription

// App/TV/ATVProtocol.swift + ATVConnection.swift werden vor dem Build hierher kopiert (siehe atv.yml).
let package = Package(
    name: "ATVCheck",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "ATVCheck")]
)
