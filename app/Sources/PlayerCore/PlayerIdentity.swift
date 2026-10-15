import Foundation

/// A player's identity in LMS: a MAC address made once and kept, so switching between Wi-Fi and
/// Ethernet never turns it into a new player, and the name file squeezelite's -N uses. One of each
/// per player (Paths.player), so each output is its own LMS player (ONE PLAYER PER DAC).
public enum PlayerIdentity {
	public static func loadOrCreateMAC(at url: URL) throws -> String {
		if let mac = mac(at: url) { return mac }
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
		bytes[0] = (bytes[0] & 0xFC) | 0x02 // locally administered, unicast
		let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
		try mac.write(to: url, atomically: true, encoding: .utf8)
		return mac
	}

	/// the player's MAC address, or nil before the agent has made one (the Settings window reads it)
	public static func mac(at url: URL) -> String? {
		guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
		let mac = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		return isValid(mac) ? mac : nil
	}

	public static func isValid(_ mac: String) -> Bool {
		mac.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil
	}

	/// 0.3.x's one player carries on as *Follow the macOS output* (Simon, 2026-10-12), so LMS keeps
	/// the same player, its name, volume and favourites, and none is left disconnected. The first time
	/// that player's identity is made, 0.3.x's MAC address and name file are copied to it; copied, not
	/// moved, and never read again once it has its own. Returns the MAC it took, or nil.
	@discardableResult
	public static func adoptOldPlayer(mac oldMAC: URL, name oldName: URL, macAt: URL, nameAt: URL) throws -> String? {
		let fm = FileManager.default
		guard !fm.fileExists(atPath: macAt.path),
			  let text = try? String(contentsOf: oldMAC, encoding: .utf8) else { return nil }
		let mac = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard isValid(mac) else { return nil }
		try fm.createDirectory(at: macAt.deletingLastPathComponent(), withIntermediateDirectories: true)
		// the name first: once the MAC is there, nothing is taken again
		if !fm.fileExists(atPath: nameAt.path), fm.fileExists(atPath: oldName.path) {
			try fm.copyItem(at: oldName, to: nameAt)
		}
		try mac.write(to: macAt, atomically: true, encoding: .utf8)
		return mac
	}

	/// The name file squeezelite's -N reads at its start: the player's name. Two things write it, and
	/// nothing else may: the Settings window's Save, for a Name typed there (`writeName`), and
	/// squeezelite, for a rename made in LMS. The agent only makes a missing one (`createNameFile`), so
	/// no default or stale name in settings.json ever writes over a rename. Before, the agent applied
	/// settings.json's names itself and had to guess which were typed (a `settings-name` record, then
	/// a `saved` flag), and a missing or unreadable settings.json still wrote the defaults' name over
	/// LMS's (/code-review 2026-10-15 (2), finding 1).
	public static func name(at url: URL) -> String? {
		(try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .newlines)
	}

	/// a player's first name file, from its settings; one that exists is left as it is
	public static func createNameFile(_ name: String, at url: URL) throws {
		guard !FileManager.default.fileExists(atPath: url.path) else { return }
		try writeName(name, at: url)
	}

	/// a Name typed in Settings, written by its Save before settings.json: whether the player, or
	/// LyrionPlay, is on or off, it is the name the engine reads at its next start
	public static func writeName(_ name: String, at url: URL) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try name.write(to: url, atomically: true, encoding: .utf8)
	}

	/// The agent, at a settings change: a running engine restarts to take a rename (Settings.renames)
	/// only when its name file holds the new name, which Save wrote there. A file holding another is
	/// LMS's rename, or the defaults' name from a settings.json gone missing, and the engine has the
	/// file's name already.
	public static func renameReached(_ name: String, at url: URL) -> Bool {
		self.name(at: url) == name
	}
}
