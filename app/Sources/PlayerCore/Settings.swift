import Foundation

public enum VolumeMode: String, Codable, Sendable, CaseIterable {
	/// LMS volume moves the device's own control: the macOS volume on built-in outputs, or a
	/// DAC's hardware volume. Offered only on a device with a volume control the Mac can set; a
	/// saved choice on one without is read as software (`nearestOffered(on:)`, ONLY WHAT A DEVICE OFFERS).
	case device
	/// LMS volume scales the samples (not bit-perfect below 100%). Offered only on a device with no
	/// volume control the Mac can set, where it is the only way LMS sets the level; a saved choice on
	/// one with a control is read as the device's own volume (SOFTWARE ONLY WITHOUT A VOLUME CONTROL).
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
	/// Fixed only on a DAC (`DeviceCaps.isExternal`), never on the Mac's own outputs (built-in,
	/// Bluetooth, AirPlay, HDMI); for *Follow the macOS output* only on a DAC with no volume control
	/// (Simon, 2026-10-14: "with not having fixed in Follow MacOS we cant set the FiiO as fixed"; it was
	/// never offered there, 2026-10-12 "MacOS 2 options"), so Follow never holds a level and its Fixed
	/// reads as the device's own volume on any output with a control; software only without a volume
	/// control (Simon, 2026-10-14: "pointless on volume control dacs its purely to add control when
	/// there is nothing at all").
	public func isOffered(by device: DeviceCaps, follow: Bool = false) -> Bool {
		switch self {
		case .device: return device.volume != nil
		case .software: return device.volume == nil
		case .fixed: return device.isExternal && (!follow || device.volume == nil)
		}
	}

	public static func offered(by device: DeviceCaps, follow: Bool = false) -> [VolumeMode] {
		allCases.filter { $0.isOffered(by: device, follow: follow) }
	}

	/// A saved choice the device does not offer, read as the nearest one it does (Simon's choice): the
	/// device's own volume without a control as software (what the engine already played it as),
	/// software with a control as the device's own volume, and Fixed where it is not offered as
	/// whichever of the two the device has.
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

	/// Only the name is required: a key a later build adds is absent from an earlier 0.4.x file and
	/// takes its default here, so settings carry over from 0.4.0 on (Simon, 2026-10-14). A field a
	/// later build adds must be optional in the same way.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		name = try c.decode(String.self, forKey: .name)
		enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
		exclusive = try c.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
		dop = try c.decodeIfPresent(Bool.self, forKey: .dop) ?? false
		volume = try c.decodeIfPresent(VolumeMode.self, forKey: .volume) ?? .device
		heldVolume = try c.decodeIfPresent(Int.self, forKey: .heldVolume)
		rateSwitchDelayMs = try c.decodeIfPresent(Int.self, forKey: .rateSwitchDelayMs) ?? 0
	}

	/// the Mac's name, as in System Settings > General > Sharing
	public static var macName: String { Host.current().localizedName ?? "Mac" }

	/// *Follow the macOS output*: on, named after the Mac, shared (macOS's outputs), its own volume
	/// where the output has one
	public static var followDefaults: PlayerSettings {
		PlayerSettings(enabled: true, name: fitName(macName), exclusive: false, dop: false, volume: .device)
	}

	/// a device's own player: off until switched on, named after the Mac then the device (Simon,
	/// 2026-10-12), exclusive on external DACs, its own volume where it has one; DoP off
	public static func defaults(for device: DeviceCaps) -> PlayerSettings {
		PlayerSettings(enabled: false, name: fitName("\(macName) \(device.name)"), exclusive: device.isExternal, dop: false,
					   volume: device.volume != nil ? .device : .software)
	}

	/// The most of a name squeezelite keeps: one line, 63 bytes (slimproto.c reads the name file
	/// with `fgets` into 64), so it is cut at a whole character here, never mid-character there. A
	/// Mac and a DAC with long names passed it in the defaults (/code-review 2026-10-15 (2), finding 3).
	/// Applied to the defaults, the only names LyrionPlay gives.
	public static let nameBytes = 63

	/// one line, trimmed, at most `nameBytes` bytes of whole characters; "" for a blank name
	public static func fitName(_ name: String) -> String {
		let line = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
		var fitted = ""
		for character in line {
			guard fitted.utf8.count + String(character).utf8.count <= nameBytes else { break }
			fitted.append(character)
		}
		return fitted.trimmingCharacters(in: .whitespaces)
	}
}

public struct Settings: Codable, Equatable, Sendable {
	/// 0.3.x files have none; they are set aside, not carried over (Simon, 2026-10-12: "no migration")
	public static let currentVersion = 2
	/// 0.4.0's version, the first with players: every file from it on is read, never set aside
	/// (SETTINGS CARRY OVER FROM 0.4.0 ON). Not `currentVersion`, which a later build raises: a file
	/// below that one needs that build's migration, not a reset.
	public static let firstPlayersVersion = 2

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

	// missing keys take the defaults, so a file from an earlier 0.4.x, without a key a later build
	// added, still loads (PlayerSettings likewise)
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
		var player = forSaving(key, device: device)
		if follow, let device { player.volume = player.volume.nearestOffered(on: device, follow: true) }
		return player
	}

	/// What the Settings window writes for a player (its Save, a player's switch, a field behind the
	/// cog). A device's own player: as `player(_:device:)` reads it, so a choice its device does not
	/// offer is saved as the one offered (ONLY WHAT A DEVICE OFFERS); its device never changes. *Follow
	/// the macOS output*: its volume choice as saved, because the device it follows changes. Corrected
	/// for an output with no volume control (the FiiO, HDMI), Save wrote Software, and Follow stayed on
	/// Software back on the speakers, without -V (inline review 2026-10-14, finding 1).
	public func forSaving(_ key: String, device: DeviceCaps?) -> PlayerSettings {
		let follow = key == PlayerKey.follow
		var player = players[key]
			?? (follow ? .followDefaults : device.map { PlayerSettings.defaults(for: $0) })
			?? PlayerSettings(enabled: false, name: key, exclusive: false, dop: false, volume: .software)
		if !follow, let device { player.volume = player.volume.nearestOffered(on: device) }
		return player
	}

	/// Without a device's player: its settings go, so it is off, and a device still connected is listed
	/// again with the defaults, as a new one. *Follow the macOS output* is never removed.
	public func removing(_ key: String) -> Settings {
		guard key != PlayerKey.follow else { return self }
		var settings = self
		settings.players[key] = nil
		return settings
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

	/// What a file holds: settings from 0.4.0 on (version 2 or later), a file from before players
	/// (0.3.x, no version), which is set aside rather than carried over, or a file that does not decode.
	public enum Stored: Equatable {
		case current(Settings)
		case older
		/// never set aside or written over by the agent, which says why: anything that did not decode
		/// was set aside as 0.3.x's, so a version-2 file a later build could not read was lost
		/// (/code-review 2026-10-14, finding 1)
		case unreadable(String)
		case missing
	}

	public static func read(from url: URL = Paths.settings) -> Stored {
		guard let data = try? Data(contentsOf: url) else { return .missing }
		do {
			// a 0.3.x file decodes, with version 0: its other keys are unknown here, but `server`,
			// `idleSeconds`, `resampleQuality` and `logLevel` are 0.3.x's too, with the same types. A
			// change of their type here would read every 0.3.x file as unreadable, never set aside
			let settings = try JSONDecoder().decode(Settings.self, from: data)
			return settings.version < firstPlayersVersion ? .older : .current(settings)
		} catch {
			return .unreadable("\(error)")
		}
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

	/// where `save` keeps a file that did not decode before writing over it
	public static func unreadableCopy(of url: URL = Paths.settings) -> URL {
		url.deletingLastPathComponent().appendingPathComponent("settings-unreadable.json")
	}

	/// Always as this build's version: a later build's file read here keeps its number in `version`,
	/// and saved back under it with only this build's keys, that build would skip its migration from
	/// this one (/code-review 2026-10-15, finding 2). A file that does not decode is kept as
	/// settings-unreadable.json first: the Settings window shows the defaults for it, and a Save there
	/// replaced it with nothing kept (/code-review 2026-10-15 (2), finding 2).
	public func save(to url: URL = Paths.settings) throws {
		if case .unreadable = Settings.read(from: url) {
			let copy = Settings.unreadableCopy(of: url)
			try? FileManager.default.removeItem(at: copy)
			try FileManager.default.moveItem(at: url, to: copy)
		}
		var stamped = self
		stamped.version = Settings.currentVersion
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(stamped).write(to: url, options: .atomic)
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
		// switched off, it waits for nothing: switched off while it waited, the agent reconciled every
		// 2 s until it was on again (/code-review 2026-10-14, finding 3)
		guard settings.isOn(PlayerKey.follow) else {
			deferred = false
			return nil
		}
		let device = settings.followDevice(in: devices, holding: holding)
		deferred = device != nil && holding != nil && settings.followDevice(in: devices)?.uid != device?.uid
		return device
	}

	/// the agent's tick: reconcile now, because the engine no longer holds the device it stayed on
	public func shouldReconcile(holding: String?) -> Bool { deferred && holding == nil }
}
