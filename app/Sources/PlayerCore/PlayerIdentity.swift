import Foundation

/// A player's identity in LMS: a MAC address made once and kept, so switching between Wi-Fi and
/// Ethernet never turns it into a new player, and the name file squeezelite's -N uses. One of each
/// per player (Paths.player), so each output is its own LMS player (ONE PLAYER PER DAC).
public enum PlayerIdentity {
	public static func loadOrCreateMAC(at url: URL) throws -> String {
		if let text = try? String(contentsOf: url, encoding: .utf8) {
			let mac = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if isValid(mac) { return mac }
		}
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
		bytes[0] = (bytes[0] & 0xFC) | 0x02 // locally administered, unicast
		let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
		try mac.write(to: url, atomically: true, encoding: .utf8)
		return mac
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

	/// The name file squeezelite's -N reads at its start, and writes LMS's renames to. A rename in
	/// Settings reaches it whether the player, or LyrionPlay, was on or off when it was saved; a rename
	/// in LMS stays. `applied` keeps the name Settings last put in the file: the file is written when
	/// there is none, or when Settings' name is no longer that one. A player from 0.4.0-0.4.5, with no
	/// record, keeps its file as it is. Before, the agent wrote a rename only for a player already
	/// running (/code-review 2026-10-14, finding 2). True when an existing file was written over: a
	/// running engine needs a restart to take it.
	/// `saved`: the name is from settings.json. False while the agent runs on the defaults because
	/// the file cannot be read: the defaults' name then only makes a missing file, never writes over
	/// one, or a rename made in LMS would be lost for good (/code-review 2026-10-15, finding 1).
	/// The file is written before the record, so a record that fails to write leaves the record
	/// older than the file, and the next call writes both again.
	@discardableResult
	public static func applyName(_ name: String, at url: URL, applied: URL, saved: Bool) throws -> Bool {
		let fm = FileManager.default
		let last = try? String(contentsOf: applied, encoding: .utf8)
		let exists = fm.fileExists(atPath: url.path)
		if exists, !saved || last == nil || last == name {
			if saved, last == nil { try name.write(to: applied, atomically: true, encoding: .utf8) }
			return false
		}
		try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try name.write(to: url, atomically: true, encoding: .utf8)
		try name.write(to: applied, atomically: true, encoding: .utf8)
		return exists
	}
}
