// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TahoeProxy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TahoeProxy", targets: ["AppUI"]),
        .library(name: "ProxyCore", targets: ["ProxyCore"]),
        .library(name: "SystemProxy", targets: ["SystemProxy"]),
        .library(name: "Subscription", targets: ["Subscription"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"])
    ],
    targets: [
        .executableTarget(
            name: "AppUI",
            dependencies: ["ProxyCore", "SystemProxy", "Subscription", "Persistence", "Diagnostics"],
            path: "Sources/AppUI"
        ),
        .target(name: "ProxyCore", dependencies: ["Diagnostics"], path: "Sources/ProxyCore"),
        .target(name: "SystemProxy", dependencies: ["Diagnostics", "Persistence"], path: "Sources/SystemProxy"),
        .target(name: "Subscription", dependencies: ["Diagnostics", "Persistence"], path: "Sources/Subscription"),
        .target(name: "Persistence", dependencies: ["Diagnostics"], path: "Sources/Persistence"),
        .target(name: "Diagnostics", path: "Sources/Diagnostics"),
        .testTarget(name: "SubscriptionTests", dependencies: ["Subscription"], path: "Tests/SubscriptionTests"),
        .testTarget(name: "RulesTests", dependencies: ["Subscription"], path: "Tests/RulesTests")
    ]
)
