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
	/// one folder per player (ONE PLAYER PER DAC)
	public static var players: URL { support.appendingPathComponent("players") }
	/// 0.3.x's one engine's PID, read once so a new agent can stop an engine an old one left
	public static var oldEnginePID: URL { support.appendingPathComponent("engine.pid") }
	/// 0.3.x's one player's MAC address and name file, which *Follow the macOS output* takes over
	/// (PlayerIdentity.adoptOldPlayer)
	public static var oldMAC: URL { support.appendingPathComponent("mac") }
	public static var oldPlayerName: URL { support.appendingPathComponent("player-name") }

	public static var agentLog: URL { logs.appendingPathComponent("agent.log") }

	/// a player's folder: its MAC address, name file (and the engine's `name.server` beside it, the
	/// servers that have named the player) and engine PID
	public static func player(_ key: String) -> URL { players.appendingPathComponent(slug(key)) }
	/// the player's MAC address, generated once
	public static func mac(_ key: String) -> URL { player(key).appendingPathComponent("mac") }
	/// squeezelite -N: the player's name as LMS has it, written by the engine (and once by
	/// PlayerIdentity.adoptOldPlayer; PlayerIdentity.name)
	public static func playerName(_ key: String) -> URL { player(key).appendingPathComponent("name") }
	/// the player's running engine's PID, so a restarted agent can stop an engine its crashed
	/// predecessor left
	public static func enginePID(_ key: String) -> URL { player(key).appendingPathComponent("engine.pid") }
	public static func engineLog(_ key: String) -> URL { logs.appendingPathComponent("engine-\(slug(key)).log") }
	/// everything LyrionPlay keeps for one player, which removing it deletes: its folder (MAC, name
	/// file, `name.server`, engine PID) and its engine log with the older copy `rotate` keeps
	public static func files(of key: String) -> [URL] {
		[player(key), engineLog(key), engineLog(key).appendingPathExtension("1")]
	}

	/// A file-safe name for a player key: "follow", or a device UID made readable (letters, digits,
	/// '.' and '-'), cut to 48 characters, plus 4 hex digits of the UID's hash, so two keys never share
	/// a folder or a log.
	public static func slug(_ key: String) -> String {
		if key == PlayerKey.follow { return key }
		var readable = ""
		for scalar in key.unicodeScalars {
			let safe = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
			if safe { readable.unicodeScalars.append(scalar) } else if !readable.hasSuffix("-") { readable += "-" }
		}
		readable = String(readable.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
		return "\(readable)-\(String(format: "%04x", fnv1a(key) & 0xFFFF))"
	}

	/// FNV-1a, 32 bits: stable across runs and builds (Swift's own Hasher is seeded per process)
	static func fnv1a(_ text: String) -> UInt32 {
		var hash: UInt32 = 2_166_136_261
		for byte in text.utf8 {
			hash ^= UInt32(byte)
			hash = hash &* 16_777_619
		}
		return hash
	}

	public static var launchAgentPlist: URL {
		home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
	}

	public static func createDirectories() throws {
		for dir in [support, logs, players] {
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
