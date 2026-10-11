// swift-tools-version:6.0
// LyrionPlay: the agent that runs the squeezelite engine, and the menu bar app that controls
// it. scripts/build.sh assembles both, plus engine/squeezelite, into one signed app bundle.
import PackageDescription

let package = Package(
	name: "LyrionPlay",
	platforms: [.macOS(.v14)],
	targets: [
		.target(name: "PlayerCore"),
		.executableTarget(name: "Agent", dependencies: ["PlayerCore"]),
		.executableTarget(name: "App", dependencies: ["PlayerCore"]),
		.testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"]),
	],
	swiftLanguageModes: [.v5]
)
