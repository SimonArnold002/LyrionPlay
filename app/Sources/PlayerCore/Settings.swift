import Foundation

public enum VolumeMode: String, Codable, Sendable, CaseIterable {
	/// LMS volume moves the device's own control: the macOS volume on built-in outputs, or a
	/// DAC's hardware volume. Offered only on a device with a volume control the Mac can set; a
	/// saved choice on one without is read as software (`nearestOffered(on:)`, ONLY WHAT A DEVICE OFFERS).
	case device
	/// LMS volume scales the samples (not bit-perfect below 100%)
	case software
	/// LMS's "Output level fixed at 100%" for this player, set by the agent (FixedVolumeSync). The
	/// engine plays at full scale whatever LMS sends. On a DAC whose volume the Mac sets (the
	/// DragonFly), its own volume is held at the level LMS had when Fixed was chosen
	/// (`PlayerSettings.heldVolume`); otherwise the DAC's knob or an amplifier sets the level
	/// (repo ledger, FIXED HOLDS THE LMS VOLUME).
	case fixed

	/// LMS's volume scales the samples in this mode: software only. From it, Fixed plays louder at
	/// once; from the device's own volume it does not (Fixed holds the level LMS had, or the samples
	/// were already at full scale). /code-review 2026-10-12, finding 2. Read it from
	/// `Settings.player(_:device:)`: the device's own volume saved on a device with no volume control
	/// comes back as software there (/code-review 2026-10-12 (2), finding 3).
	public var scalesSamples: Bool { self == .software }

	/// What a device offers (Simon, 2026-10-12: "block device volume as an option if it doesnt offer
	/// it, block fixed on MacOS outputs"): its own volume only with a volume control the Mac can set;
	/// Fixed at 100% only on a DAC (`DeviceCaps.isExternal`), never on the Mac's own outputs (built-in,
	/// Bluetooth, AirPlay, HDMI), and never for *Follow the macOS output* (Simon, 2026-10-12: "MacOS 2
	/// options"); software on every device.
	public func isOffered(by device: DeviceCaps, follow: Bool = false) -> Bool {
		switch self {
		case .device: return device.volume != nil
		case .software: return true
		case .fixed: return !follow && device.isExternal
		}
	}

	public static func offered(by device: DeviceCaps, follow: Bool = false) -> [VolumeMode] {
		allCases.filter { $0.isOffered(by: device, follow: follow) }
	}

	/// A saved choice the device does not offer, read as the nearest one it does (Simon's choice): the
	/// device's own volume without a control as software (what the engine already played it as),
	/// Fixed where it is not offered as the device's own volume, or software without a control.
	public func nearestOffered(on device: DeviceCaps, follow: Bool = false) -> VolumeMode {
		isOffered(by: device, follow: follow) ? self : device.volume != nil ? .device : .software
	}
}

/// The keys of `Settings.players`: *Follow the macOS output*, or a device UID.
public enum PlayerKey {
	public static let follow = "follow"
}

/// One player's settings (repo ledger, ONE PLAYER PER DAC): each is its own squeezelite and its own
/// LMS player, so LMS's saved volume and fixed setting stay with it.
public struct PlayerSettings: Codable, Equatable, Sendable {
	/// the player runs (the switch on its row in Settings)
	public var enabled: Bool
	public var name: String
	public var exclusive: Bool
	/// the DAC accepts DSD over PCM; macOS cannot report it, so it is a switch
	public var dop: Bool
	public var volume: VolumeMode
	/// Fixed on a device with a volume control: the LMS volume (1...100) its own volume is held at,
	/// read from LMS when Fixed was chosen (HeldVolume)
	public var heldVolume: Int?
	/// silence added when the sample rate changes, for DACs that clip the first notes
	public var rateSwitchDelayMs: Int

	public init(enabled: Bool, name: String, exclusive: Bool, dop: Bool, volume: VolumeMode, heldVolume: Int? = nil,
				rateSwitchDelayMs: Int = 0) {
		self.enabled = enabled
		self.name = name
		self.exclusive = exclusive
		self.dop = dop
		self.volume = volume
		self.heldVolume = heldVolume
		self.rateSwitchDelayMs = rateSwitchDelayMs
	}

	/// the Mac's name, as in System Settings > General > Sharing
	public static var macName: String { Host.current().localizedName ?? "Mac" }

	/// *Follow the macOS output*: on, named after the Mac, shared (macOS's outputs), its own volume
	/// where the output has one
	public static var followDefaults: PlayerSettings {
		PlayerSettings(enabled: true, name: macName, exclusive: false, dop: false, volume: .device)
	}

	/// a device's own player: off until switched on, named after the Mac then the device (Simon,
	/// 2026-10-12), exclusive on external DACs, its own volume where it has one; DoP off
	public static func defaults(for device: DeviceCaps) -> PlayerSettings {
		PlayerSettings(enabled: false, name: "\(macName) \(device.name)", exclusive: device.isExternal, dop: false,
					   volume: device.volume != nil ? .device : .software)
	}
}

public struct Settings: Codable, Equatable, Sendable {
	/// 0.3.x files have none; they are set aside, not carried over (Simon, 2026-10-12: "no migration")
	public static let currentVersion = 2

	public var version: Int
	/// "" = find the server on the network; otherwise host or host:port (slimproto port)
	public var server: String
	/// release the device (and exclusive mode) after this many seconds stopped; 0 = never
	public var idleSeconds: Int
	/// squeezelite -R quality letter. The app offers v (very high), h and m; -R also takes l and q,
	/// which only a hand-edited settings file holds (the Settings picker then shows no choice).
	public var resampleQuality: String
	/// squeezelite log level: info, debug or sdebug
	public var logLevel: String
	/// keyed `PlayerKey.follow` or a device UID
	public var players: [String: PlayerSettings]

	public init() {
		version = Settings.currentVersion
		server = ""
		idleSeconds = 30
		resampleQuality = "v"
		logLevel = "info"
		players = [PlayerKey.follow: .followDefaults]
	}

	// missing keys take the defaults, so a hand-edited file still loads
	public init(from decoder: Decoder) throws {
		let defaults = Settings()
		let c = try decoder.container(keyedBy: CodingKeys.self)
		version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
		server = try c.decodeIfPresent(String.self, forKey: .server) ?? defaults.server
		idleSeconds = try c.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? defaults.idleSeconds
		resampleQuality = try c.decodeIfPresent(String.self, forKey: .resampleQuality) ?? defaults.resampleQuality
		logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? defaults.logLevel
		players = try c.decodeIfPresent([String: PlayerSettings].self, forKey: .players) ?? defaults.players
	}

	/// Every reader takes a player's settings here (the engine's arguments, the agent's LMS sync, the
	/// Settings window): saved, or the defaults, with a volume choice the device does not offer read
	/// as one it does. `device`: the device the player plays to; nil when it is not connected.
	public func player(_ key: String, device: DeviceCaps?) -> PlayerSettings {
		let follow = key == PlayerKey.follow
		var player = players[key]
			?? (follow ? .followDefaults : device.map { PlayerSettings.defaults(for: $0) })
			?? PlayerSettings(enabled: false, name: key, exclusive: false, dop: false, volume: .software)
		if let device { player.volume = player.volume.nearestOffered(on: device, follow: follow) }
		return player
	}

	public func isOn(_ key: String) -> Bool {
		players[key]?.enabled ?? (key == PlayerKey.follow)
	}

	/// The device *Follow the macOS output* plays to: the macOS output, or the Mac's built-in output
	/// (the first built-in device the engine lists) when the macOS output has its own player on
	/// (Simon, 2026-10-10). `holding`: the device the follow player holds exclusively right now; it
	/// stays on it while it does, because macOS moves its default output away from a device another
	/// process holds, and back when it is let go (measured 2026-10-10, under 10 ms each way):
	/// following that would restart the player on another device mid-track. Never a device that has
	/// its own player on, held or not.
	public func followDevice(in devices: [DeviceCaps], holding: String? = nil) -> DeviceCaps? {
		if let holding, !isOn(holding), let held = devices.first(where: { $0.uid == holding }) { return held }
		guard let output = devices.first(where: \.isDefault) else { return nil }
		if !output.isBuiltIn, isOn(output.uid) { return devices.first(where: \.isBuiltIn) }
		return output
	}

	/// What a file holds: the current settings, or a file from before players (0.3.x), which is
	/// set aside rather than carried over.
	public enum Stored: Equatable {
		case current(Settings)
		case older
		case missing
	}

	public static func read(from url: URL = Paths.settings) -> Stored {
		guard let data = try? Data(contentsOf: url) else { return .missing }
		guard let settings = try? JSONDecoder().decode(Settings.self, from: data),
			  settings.version == currentVersion else { return .older }
		return .current(settings)
	}

	/// A missing, unreadable or older file gives the defaults.
	public static func load(from url: URL = Paths.settings) -> Settings {
		if case .current(let settings) = read(from: url) { return settings }
		return Settings()
	}

	/// The agent at start: an older file moves to settings-0.3.json, and the defaults are written in its
	/// place. Returns where it went, or nil if there was nothing to set aside.
	@discardableResult
	public static func setAsideOlder(at url: URL = Paths.settings) throws -> URL? {
		guard read(from: url) == .older else { return nil }
		let aside = url.deletingLastPathComponent().appendingPathComponent("settings-0.3.json")
		try? FileManager.default.removeItem(at: aside)
		try FileManager.default.moveItem(at: url, to: aside)
		try Settings().save(to: url)
		return aside
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

	/// the device to play to; holding is the device the follow player's engine holds exclusively now
	public mutating func resolve(_ settings: Settings, in devices: [DeviceCaps], holding: String?) -> DeviceCaps? {
		let device = settings.followDevice(in: devices, holding: holding)
		deferred = device != nil && holding != nil && settings.followDevice(in: devices)?.uid != device?.uid
		return device
	}

	/// the agent's tick: reconcile now, because the engine no longer holds the device it stayed on
	public func shouldReconcile(holding: String?) -> Bool { deferred && holding == nil }
}
