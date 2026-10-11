import Foundation

/// The player's identity in LMS: a MAC address made once and kept, so switching between Wi-Fi and
/// Ethernet never turns this Mac into a new player, and the name file squeezelite's -N uses.
public enum PlayerIdentity {
	public static func loadOrCreateMAC(at url: URL = Paths.mac) throws -> String {
		if let text = try? String(contentsOf: url, encoding: .utf8) {
			let mac = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if isValid(mac) { return mac }
		}
		var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
		bytes[0] = (bytes[0] & 0xFC) | 0x02 // locally administered, unicast
		let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
		try mac.write(to: url, atomically: true, encoding: .utf8)
		return mac
	}

	public static func isValid(_ mac: String) -> Bool {
		mac.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil
	}

	/// Created once with the chosen name; after that squeezelite owns it (LMS renames land there).
	public static func ensureNameFile(at url: URL = Paths.playerName, name: String) throws {
		guard !FileManager.default.fileExists(atPath: url.path) else { return }
		try name.write(to: url, atomically: true, encoding: .utf8)
	}
}
