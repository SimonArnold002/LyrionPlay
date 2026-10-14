import Foundation

/// One output device as the engine reports it (`squeezelite -l`, one JSON object per line).
/// The engine's probe is the only source of capabilities: the agent and the app never re-derive them.
public struct DeviceCaps: Codable, Equatable, Hashable, Sendable, Identifiable {
	public struct VolumeControl: Codable, Equatable, Hashable, Sendable {
		public var control: String
		public var dbMin: Double
		public var dbMax: Double
		public var mute: Bool

		enum CodingKeys: String, CodingKey {
			case control, mute
			case dbMin = "db_min"
			case dbMax = "db_max"
		}
	}

	public var uid: String
	public var name: String
	public var manufacturer: String
	public var transport: String
	public var isDefault: Bool
	public var channels: Int
	public var rates: [Int]
	public var integerBits: [Int]
	public var float: Bool
	public var volume: VolumeControl?
	public var exclusiveOwner: Int
	public var currentRate: Int?
	public var currentFormat: String?

	public var id: String { uid }

	enum CodingKeys: String, CodingKey {
		case uid, name, manufacturer, transport, channels, rates, float, volume
		case isDefault = "default"
		case integerBits = "integer_bits"
		case exclusiveOwner = "exclusive_owner"
		case currentRate = "current_rate"
		case currentFormat = "current_format"
	}

	public var maxRate: Int { rates.first ?? 44100 }

	/// a DAC-style connection, where exclusive mode is the default
	public var isExternal: Bool { ["usb", "thunderbolt", "firewire", "pci", "avb"].contains(transport) }

	/// the Mac's own speakers or headphones: reached through *Follow the macOS output*, never a player
	/// of their own (Simon, 2026-10-12)
	public var isBuiltIn: Bool { transport == "builtin" }

	/// "44.1-384 kHz" for the device picker
	public var rateSummary: String {
		guard let low = rates.last, let high = rates.first else { return "no rates" }
		return low == high ? Self.kHz(high) : "\(Self.kHz(low))-\(Self.kHz(high))"
	}

	public static func kHz(_ rate: Int) -> String {
		rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
	}

	/// Parses `squeezelite -l` output; lines that are not a device object are skipped.
	public static func parseList(_ text: String) -> [DeviceCaps] {
		let decoder = JSONDecoder()
		return text.split(whereSeparator: \.isNewline).compactMap { line in
			guard line.first == "{" else { return nil }
			return try? decoder.decode(DeviceCaps.self, from: Data(line.utf8))
		}
	}

	/// Runs the engine's probe. Blocking; takes well under a second.
	public static func probe(engine: URL) -> [DeviceCaps] {
		let process = Process()
		process.executableURL = engine
		process.arguments = ["-l"]
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
		} catch {
			return []
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return parseList(String(decoding: data, as: UTF8.self))
	}
}
