import Foundation

/// On/Off for the player: a classic per-user launch agent. SMAppService cannot be used with this
/// app's self-signed identity: it pins the agent to its first build, and every rebuild then dies
/// with "Launch Constraint Violation" (repo ledger, SMAPPSERVICE PINS THE FIRST BUILD).
public enum LaunchAgent {
	/// The plist being present is what starts the agent at login.
	public static var isOn: Bool { FileManager.default.fileExists(atPath: Paths.launchAgentPlist.path) }

	public static func plist(agent: URL) -> [String: Any] {
		[
			"Label": Paths.agentLabel,
			"Program": agent.path,
			"RunAtLoad": true,
			// restart after a crash, but not after a clean exit (Off sends SIGTERM)
			"KeepAlive": ["SuccessfulExit": false],
			// never throttled like a background job: it feeds an audio device
			"ProcessType": "Interactive",
			"AssociatedBundleIdentifiers": [Paths.bundleID],
		]
	}

	@discardableResult
	public static func turnOn(agent: URL) throws -> String {
		let url = Paths.launchAgentPlist
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let data = try PropertyListSerialization.data(fromPropertyList: plist(agent: agent), format: .xml, options: 0)
		try data.write(to: url, options: .atomic)
		_ = launchctl(["bootout", "\(domain)/\(Paths.agentLabel)"])
		let (status, output) = launchctl(["bootstrap", domain, url.path])
		if status != 0 {
			throw NSError(domain: "LaunchAgent", code: Int(status),
						  userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(output)"])
		}
		return output
	}

	public static func turnOff() {
		stop()
		try? FileManager.default.removeItem(at: Paths.launchAgentPlist)
	}

	/// Quit in the menu: stops the player now and keeps the plist, so login starts it again
	public static func stop() {
		_ = launchctl(["bootout", "\(domain)/\(Paths.agentLabel)"])
	}

	/// opening the menu app starts a player that is on but was stopped by Quit
	public static func startIfOn(agent: URL) throws {
		guard isOn, !isLoaded else { return }
		try turnOn(agent: agent)
	}

	public static var isLoaded: Bool { launchctl(["print", "\(domain)/\(Paths.agentLabel)"]).0 == 0 }

	static var domain: String { "gui/\(getuid())" }

	static func launchctl(_ args: [String]) -> (Int32, String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
		process.arguments = args
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		do {
			try process.run()
		} catch {
			return (-1, error.localizedDescription)
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return (process.terminationStatus, String(decoding: data, as: UTF8.self))
	}
}
