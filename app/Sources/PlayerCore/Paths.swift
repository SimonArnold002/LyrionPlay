import Foundation

/// Where the agent and the app keep their files. Everything is per user; nothing is system-wide.
public enum Paths {
	public static let bundleID = "com.crystalgipsy.lyrionplay"
	public static let agentLabel = "com.crystalgipsy.lyrionplay.agent"

	static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

	public static var support: URL { home.appendingPathComponent("Library/Application Support/LyrionPlay") }
	public static var logs: URL { home.appendingPathComponent("Library/Logs/LyrionPlay") }

	/// written by the app, read by the agent
	public static var settings: URL { support.appendingPathComponent("settings.json") }
	/// written by the agent, read by the app
	public static var status: URL { support.appendingPathComponent("status.json") }
	/// the player's MAC address, generated once
	public static var mac: URL { support.appendingPathComponent("mac") }
	/// squeezelite -N: holds the player name, and LMS's renames are written back to it
	public static var playerName: URL { support.appendingPathComponent("player-name") }
	/// the running engine's PID, so a restarted agent can stop an engine its crashed predecessor left
	public static var enginePID: URL { support.appendingPathComponent("engine.pid") }

	public static var agentLog: URL { logs.appendingPathComponent("agent.log") }
	public static var engineLog: URL { logs.appendingPathComponent("engine.log") }

	public static var launchAgentPlist: URL {
		home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
	}

	public static func createDirectories() throws {
		for dir in [support, logs] {
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		}
	}

	/// the app bundle the running executable belongs to; not an .app on a development run
	public static var appBundle: URL { Bundle.main.bundleURL }

	/// The executables sit together in the app bundle's Contents/MacOS. Found through the bundle,
	/// never argv[0] (see the repo ledger, ARGV0 IS BUNDLE-RELATIVE). LYRIONPLAY_ENGINE overrides it for
	/// development runs outside a bundle.
	public static func executable(_ name: String) -> URL {
		if name == "squeezelite", let override = ProcessInfo.processInfo.environment["LYRIONPLAY_ENGINE"] {
			return URL(fileURLWithPath: override)
		}
		return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)")
	}
}
