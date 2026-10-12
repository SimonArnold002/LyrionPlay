import Foundation

public enum VolumeMode: String, Codable, Sendable, CaseIterable {
	/// LMS volume moves the device's own control: the macOS volume on built-in outputs, or a
	/// DAC's hardware volume. Offered only on a device with a volume control the Mac can set; a
	/// saved choice on one without is read as software (`nearestOffered(on:)`, ONLY WHAT A DEVICE OFFERS).
	case device
	/// LMS volume scales the samples (not bit-perfect below 100%)
	case software
	/// LMS's "Output level fixed at 100%" for this player, set by the agent (FixedVolumeSync).
	/// The music goes at full level, and the device's own volume is left alone: the DAC's knob or an
	/// amplifier sets it (repo ledger, FIXED AT 100% PER DAC).
	case fixed

	/// LMS's volume scales the samples in this mode: software only. From it, Fixed plays louder at
	/// once; from the device's own volume it does not (the level stays where LMS left it, and the
	/// samples were already at full scale). /code-review 2026-10-12, finding 2. Read it from
	/// `Settings.options(for:)`: the device's own volume saved on a device with no volume control
	/// comes back as software there (/code-review 2026-10-12 (2), finding 3).
	public var scalesSamples: Bool { self == .software }

	/// What a device offers (Simon, 2026-10-12: "block device volume as an option if it doesnt offer
	/// it, block fixed on MacOS outputs"): its own volume only with a volume control the Mac can set;
	/// Fixed at 100% only on a DAC (`DeviceCaps.isExternal`), never on the Mac's own outputs (built-in,
	/// Bluetooth, AirPlay, HDMI); software on every device.
	public func isOffered(by device: DeviceCaps) -> Bool {
		switch self {
		case .device: return device.volume != nil
		case .software: return true
		case .fixed: return device.isExternal
		}
	}

	public static func offered(by device: DeviceCaps) -> [VolumeMode] {
		allCases.filter { $0.isOffered(by: device) }
	}

	/// A saved choice the device does not offer, read as the nearest one it does (Simon's choice): the
	/// device's own volume without a control as software (what the engine already played it as),
	/// Fixed on a Mac output as the device's own volume, or software without a control.
	public func nearestOffered(on device: DeviceCaps) -> VolumeMode {
		isOffered(by: device) ? self : device.volume != nil ? .device : .software
	}
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

	/// Every reader takes a device's options here (the engine's arguments, the agent's LMS sync, the
	/// Settings window), so a saved volume choice the device does not offer is read as one it does.
	public func options(for device: DeviceCaps) -> DeviceOptions {
		var options = devices[device.uid] ?? .defaults(for: device)
		options.volume = options.volume.nearestOffered(on: device)
		return options
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
