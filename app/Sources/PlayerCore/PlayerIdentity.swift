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

	/// The player's name in LMS, as its name file holds it: squeezelite writes there every name LMS
	/// sends, and LMS sends its own at each connect (LMS OWNS THE PLAYER NAME). nil before LMS has
	/// named the player, or for an empty file. Nothing in LyrionPlay writes it; a player is renamed in
	/// LMS only.
	public static func name(at url: URL) -> String? {
		let name = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .newlines)
		return name?.isEmpty == false ? name : nil
	}
}
