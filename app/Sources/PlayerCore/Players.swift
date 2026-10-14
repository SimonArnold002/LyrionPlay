import Foundation

/// One row of the Settings window's player list, and one player that can run.
public struct PlayerRow: Equatable, Sendable, Identifiable {
	public var key: String
	/// the device it plays to; for *Follow the macOS output*, the one it follows now. nil: not connected
	public var device: DeviceCaps?

	public var id: String { key }
	public var isFollow: Bool { key == PlayerKey.follow }
}

public enum PlayerList {
	/// *Follow the macOS output* first; then every device the engine lists except the Mac's built-in
	/// outputs, in the engine's order; then devices with saved settings that are not connected, by
	/// name (Simon, 2026-10-12). `holding`: the device the follow player holds (Settings.followDevice).
	public static func rows(settings: Settings, devices: [DeviceCaps], holding: String? = nil) -> [PlayerRow] {
		var rows = [PlayerRow(key: PlayerKey.follow, device: settings.followDevice(in: devices, holding: holding))]
		rows += devices.filter { !$0.isBuiltIn }.map { PlayerRow(key: $0.uid, device: $0) }
		let listed = Set(rows.map(\.key))
		rows += settings.players.keys
			.filter { !listed.contains($0) && $0 != PlayerKey.follow }
			.sorted { (settings.players[$0]?.name ?? $0) < (settings.players[$1]?.name ?? $1) }
			.map { PlayerRow(key: $0, device: nil) }
		return rows
	}
}

/// One engine to run: a player that is on, on its device.
public struct EngineSpec: Equatable, Sendable {
	public var key: String
	public var device: DeviceCaps
	public var args: [String]

	public init(key: String, device: DeviceCaps, args: [String]) {
		self.key = key
		self.device = device
		self.args = args
	}
}

public enum EnginePlan {
	/// Each player that is on and whose device is connected. `followDevice`: where *Follow the macOS
	/// output* plays (OutputFollow); `args`: a player's engine arguments on a device.
	public static func make(settings: Settings, devices: [DeviceCaps], followDevice: DeviceCaps?,
							args: (String, DeviceCaps) -> [String]) -> [String: EngineSpec] {
		var plan: [String: EngineSpec] = [:]
		if settings.isOn(PlayerKey.follow), let device = followDevice {
			plan[PlayerKey.follow] = EngineSpec(key: PlayerKey.follow, device: device, args: args(PlayerKey.follow, device))
		}
		for device in devices where !device.isBuiltIn && settings.isOn(device.uid) {
			plan[device.uid] = EngineSpec(key: device.uid, device: device, args: args(device.uid, device))
		}
		return plan
	}

	/// What to stop and what to start, given the arguments each running engine was started with. A
	/// player whose arguments are the same is left running; the agent stops everything listed before
	/// it starts anything, so two engines never hold one device.
	public static func changes(running: [String: [String]], wanted: [String: EngineSpec]) -> (stop: [String], start: [String]) {
		let stop = running.filter { wanted[$0.key]?.args != $0.value }.map(\.key).sorted()
		let start = wanted.filter { running[$0.key] != $0.value.args }.map(\.key).sorted()
		return (stop, start)
	}
}

/// The level Fixed holds on a device with a volume control: the volume LMS has saved for the player
/// when Fixed is chosen (Simon, 2026-10-12: "set the volume to the limit I want then chnage the
/// settings to fixed"; FIXED HOLDS THE LMS VOLUME).
public enum HeldVolume: Equatable, Sendable {
	case held(Int)
	case refused(String)

	/// `lmsVolume`: `mixer volume ?`, the SAVED volume, negative while muted (MIXER VOLUME ? IS THE
	/// SAVED VOLUME); nil when LMS did not answer.
	public static func from(lmsVolume: Double?) -> HeldVolume {
		guard let lmsVolume else {
			return .refused("LMS did not answer, so the volume to hold is not known: Fixed is not saved.")
		}
		// a muted player keeps its level, as a negative number
		let level = min(Int(abs(lmsVolume).rounded()), 100)
		guard level > 0 else {
			return .refused("LMS's volume for this player is 0: set it in LMS first, then choose Fixed.")
		}
		return .held(level)
	}

	/// the device level for a held LMS volume: the curve *Device's own volume* uses (LMSVolume)
	public static func dB(_ volume: Int) -> Double { LMSVolume.dB(volume) }
}
