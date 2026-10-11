import Foundation

public enum VolumeMode: String, Codable, Sendable, CaseIterable {
	/// LMS volume moves the device's own control: the macOS volume on built-in outputs, or a
	/// DAC's hardware volume. The engine falls back to software volume if the device has none.
	case device
	/// LMS volume scales the samples (not bit-perfect below 100%)
	case software
}

/// Options for one output device, keyed by its UID.
public struct DeviceOptions: Codable, Equatable, Sendable {
	public var exclusive: Bool
	/// the DAC accepts DSD over PCM; macOS cannot report it, so it is a switch
	public var dop: Bool
	public var volume: VolumeMode
	/// silence added when the sample rate changes, for DACs that clip the first notes
	public var rateSwitchDelayMs: Int

	public init(exclusive: Bool, dop: Bool, volume: VolumeMode, rateSwitchDelayMs: Int = 0) {
		self.exclusive = exclusive
		self.dop = dop
		self.volume = volume
		self.rateSwitchDelayMs = rateSwitchDelayMs
	}

	/// Exclusive on external DACs, shared on built-in, Bluetooth, AirPlay and HDMI outputs; the
	/// device's own volume where it has one; DoP off.
	public static func defaults(for device: DeviceCaps) -> DeviceOptions {
		DeviceOptions(exclusive: device.isExternal, dop: false, volume: device.volume != nil ? .device : .software)
	}
}

public struct Settings: Codable, Equatable, Sendable {
	public var playerName: String
	/// "" = find the server on the network; otherwise host or host:port (slimproto port)
	public var server: String
	/// a device UID, or "default" to follow the macOS output device
	public var outputDevice: String
	public var devices: [String: DeviceOptions]
	/// release the device (and exclusive mode) after this many seconds stopped; 0 = never
	public var idleSeconds: Int
	/// squeezelite -R quality letter. The app offers v (very high), h and m; -R also takes l and q,
	/// which only a hand-edited settings file holds (the Settings picker then shows no choice).
	public var resampleQuality: String
	/// squeezelite log level: info, debug or sdebug
	public var logLevel: String

	public static let followSystem = "default"

	public init() {
		playerName = Host.current().localizedName ?? "Mac"
		server = ""
		outputDevice = Settings.followSystem
		devices = [:]
		idleSeconds = 30
		resampleQuality = "v"
		logLevel = "info"
	}

	// missing keys take the defaults, so an older settings file still loads
	public init(from decoder: Decoder) throws {
		let defaults = Settings()
		let c = try decoder.container(keyedBy: CodingKeys.self)
		playerName = try c.decodeIfPresent(String.self, forKey: .playerName) ?? defaults.playerName
		server = try c.decodeIfPresent(String.self, forKey: .server) ?? defaults.server
		outputDevice = try c.decodeIfPresent(String.self, forKey: .outputDevice) ?? defaults.outputDevice
		devices = try c.decodeIfPresent([String: DeviceOptions].self, forKey: .devices) ?? defaults.devices
		idleSeconds = try c.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? defaults.idleSeconds
		resampleQuality = try c.decodeIfPresent(String.self, forKey: .resampleQuality) ?? defaults.resampleQuality
		logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? defaults.logLevel
	}

	public func options(for device: DeviceCaps) -> DeviceOptions {
		devices[device.uid] ?? .defaults(for: device)
	}

	/// The device the settings point at, among those the engine reported. `holding`: the device
	/// the player holds exclusively right now. "Follow the macOS output" stays on it while it does,
	/// because macOS moves its default output away from a device another process holds, and back
	/// when it is let go (measured 2026-10-10, under 10 ms each way): following that would restart
	/// the player on another device mid-track.
	public func resolveDevice(in devices: [DeviceCaps], holding: String? = nil) -> DeviceCaps? {
		guard outputDevice == Settings.followSystem else { return devices.first(where: { $0.uid == outputDevice }) }
		if let holding, let held = devices.first(where: { $0.uid == holding }) { return held }
		return devices.first(where: \.isDefault)
	}

	/// A missing or unreadable file gives the defaults.
	public static func load(from url: URL = Paths.settings) -> Settings {
		guard let data = try? Data(contentsOf: url),
			  let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
		return settings
	}

	public func save(to url: URL = Paths.settings) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(self).write(to: url, options: .atomic)
	}
}

/// "Follow the macOS output" with exclusive access. macOS moves its default output away from a
/// device the engine holds (HOG MOVES THE DEFAULT OUTPUT), so while the engine holds one the player
/// stays on it, and follows the macOS output again once the engine lets go. Only resolve changes
/// the state: stopping or restarting the engine must not lose a follow that is waiting (a restart
/// on the held device lets go of it, and nothing else would announce that).
public struct OutputFollow: Sendable {
	/// the macOS output is elsewhere while the engine holds its device: follow it once it lets go
	public private(set) var deferred = false

	public init() {}

	/// the device to play to; holding is the device the engine holds exclusively right now
	public mutating func resolve(_ settings: Settings, in devices: [DeviceCaps], holding: String?) -> DeviceCaps? {
		let device = settings.resolveDevice(in: devices, holding: holding)
		deferred = device != nil && holding != nil && settings.resolveDevice(in: devices)?.uid != device?.uid
		return device
	}

	/// the agent's tick: reconcile now, because the engine no longer holds the device it stayed on
	public func shouldReconcile(holding: String?) -> Bool { deferred && holding == nil }
}
