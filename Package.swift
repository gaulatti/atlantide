// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AtlantideResilience",
    platforms: [.tvOS(.v26)],
    products: [
        .library(name: "AtlantideResilience", targets: ["AtlantideResilience"]),
    ],
    targets: [
        .target(
            name: "AtlantideResilience",
            path: "celesti",
            exclude: [
                "Assets.xcassets",
                "ChannelLibrary.swift",
                "CelestiStore.swift",
                "ContentView.swift",
                "DvrViews.swift",
                "EmergencyPlaybackView.swift",
                "EmergencyPlayerController.swift",
                "QuadPlaybackView.swift",
                "QuadPlayerController.swift",
                "Quadrant.swift",
                "TelemetryReporter.swift",
                "celestiApp.swift",
            ],
            sources: ["PlaybackResiliencePolicy.swift"]
        ),
        .testTarget(
            name: "AtlantideResilienceTests",
            dependencies: ["AtlantideResilience"],
            path: "Tests/AtlantideResilienceTests"
        ),
    ]
)
