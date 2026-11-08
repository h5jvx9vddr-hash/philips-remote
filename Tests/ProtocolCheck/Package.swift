// swift-tools-version:5.9
import PackageDescription

// App/TV/PhilipsClient.swift, Keys.swift und Discovery.swift werden vor dem Build hierher kopiert (siehe protocol.yml).
let package = Package(
    name: "ProtocolCheck",
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
    targets: [.executableTarget(name: "ProtocolCheck", dependencies: [.product(name: "Crypto", package: "swift-crypto")])]
)
