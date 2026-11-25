// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "chargelight",
    platforms: [.macOS(.v12)],
    products: [
        // Swift API: read/set the LED, and the agent-status layer (claims).
        .library(name: "ChargeLight", targets: ["ChargeLight"]),
        // C API: raw AppleSMC access, usable from C, Objective-C, Rust, Zig, ...
        .library(name: "CChargeLightSMC", targets: ["CChargeLightSMC"]),
        .executable(name: "chargelight", targets: ["chargelight-cli"]),
        .executable(name: "chargelight-helper", targets: ["chargelight-helper"]),
    ],
    targets: [
        .target(
            name: "CChargeLightSMC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "ChargeLight", dependencies: ["CChargeLightSMC"]),
        // The whole CLI lives in a library so it can be tested in-process.
        .target(name: "ChargeLightCommands", dependencies: ["ChargeLight"]),
        .executableTarget(name: "chargelight-cli", dependencies: ["ChargeLightCommands"]),
        .executableTarget(name: "chargelight-helper", dependencies: ["CChargeLightSMC"]),
        .testTarget(
            name: "ChargeLightTests",
            dependencies: ["ChargeLight", "ChargeLightCommands"]
        ),
    ]
)
