import Foundation

/// One `lyrionplay:volume <dB> <muted> <lms> <moved>` line from the engine (output_coreaudio.c,
/// volume_listener): the Mac's volume keys or menu bar slider moved the device.
public struct VolumeReport: Equatable, Sendable {
	/// LMS's last `audg`, as the engine got it
	public enum LMSLevel: Int, Sendable {
		/// none yet: LMS sends its level at the connect (repo ledger, LMS SENDS VOLUME ON CONNECT),
		/// so only before that; whether its volume is fixed is not known either
		case unknown = -1
		/// silence: LMS is muted, or at volume 0
		case silent = 0
		/// a level, so LMS is not muted
		case audible = 1
	}

	public var dB: Double
	public var muted: Bool
	public var lms: LMSLevel
	/// the level moved; false when only the mute changed (the Mac's mute key)
	public var levelMoved: Bool

	public init(dB: Double, muted: Bool, lms: LMSLevel, levelMoved: Bool = true) {
		self.dB = dB
		self.muted = muted
		self.lms = lms
		self.levelMoved = levelMoved
	}

	/// nil for any other line. A line without <lms> counts as unknown, so the agent asks LMS; one
	/// without <moved> as a level that moved.
	public init?(line: some StringProtocol) {
		let fields = line.split(separator: " ")
		guard (3...5).contains(fields.count), fields[0] == "lyrionplay:volume",
			  let dB = Double(fields[1]), fields[2] == "0" || fields[2] == "1" else { return nil }
		if fields.count == 5 && fields[4] != "0" && fields[4] != "1" { return nil }
		self.dB = dB
		muted = fields[2] == "1"
		lms = fields.count >= 4 ? Int(fields[3]).flatMap(LMSLevel.init(rawValue:)) ?? .unknown : .unknown
		levelMoved = fields.count < 5 || fields[4] == "1"
	}
}

/// What to ask LMS for one report.
public enum VolumePush {
	/// `volumeFixed` reads `playerpref digitalVolumeControl ?` and `lmsVolume` reads `mixer volume ?`;
	/// each is asked only when the report cannot answer it (LMS answers in about 27 ms when idle,
	/// measured 2026-10-10, and holding a volume key pushes every 150 ms). nil: send nothing.
	public static func command(for report: VolumeReport,
							   volumeFixed: () async -> Bool?,
							   lmsVolume: () async -> Double?) async -> [String]? {
		// Before any audg the engine cannot tell whether LMS's volume is fixed, and a fixed player
		// takes no volume from the Mac (repo ledger, FIXED VOLUME LEAVES THE DEVICE ALONE).
		if report.lms == .unknown, await volumeFixed() == true { return nil }
		if report.muted { return ["mixer", "muting", "1"] }
		// The Mac's unmute key alone while LMS is muted asks LMS to unmute, so it fades back to the
		// volume it kept. A level would be wrong: LMS faded the device to its minimum when it
		// muted (measured 2026-10-09: unmute gave LMS volume 7 instead of 42; UNMUTE IS NOT A
		// LEVEL). LMS stores a muted volume as a negative number. A report of LMS at a level
		// needs no question: LMS is not muted. A level the user MOVED goes to LMS as that level
		// even while LMS is muted: `mixer volume N` unmutes it at N (mixerCommand; measured on the
		// rig 2026-10-14: muted at -42, `mixer volume 30` gave 30, muting 0). Unmuting to the kept
		// volume moved the device off the level the user had just set (Simon, 2026-10-14).
		if report.lms != .audible, !report.levelMoved, let current = await lmsVolume(), current < 0 {
			return ["mixer", "muting", "0"]
		}
		return ["mixer", "volume", String(LMSVolume.volume(forDB: report.dB))]
	}
}

/// Sends values one at a time, in order, and the newest wins: while a send is in flight, later
/// values replace each other and only the last is sent once it finishes. At most one send starts
/// per `interval`. Two pushes in flight at once could reach LMS out of order, and the older level
/// would stick.
public final class LatestValueSender<Value: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var pending: Value?
	private var busy = false
	private var lastStart = Date.distantPast
	private let interval: TimeInterval
	private let send: @Sendable (Value) async -> Void

	public init(interval: TimeInterval, send: @escaping @Sendable (Value) async -> Void) {
		self.interval = interval
		self.send = send
	}

	public func submit(_ value: Value) {
		let start = lock.withLock {
			pending = value
			defer { busy = true }
			return !busy
		}
		if start { Task.detached { await self.drain() } }
	}

	private func drain() async {
		while true {
			let wait: TimeInterval? = lock.withLock {
				guard pending != nil else {
					busy = false
					return nil
				}
				return max(0, interval - Date().timeIntervalSince(lastStart))
			}
			guard let wait else { return }
			if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
			let value: Value? = lock.withLock {
				defer { pending = nil }
				lastStart = Date()
				return pending
			}
			if let value { await send(value) }
		}
	}
}

/// "Fixed at 100%" per DAC (Simon, 2026-10-11): LMS's "Output level fixed at 100%" for this player
/// (`playerpref digitalVolumeControl`, 0 = fixed) follows the "LMS volume" setting of the device
/// the engine plays to. Fixed sets it; the other modes turn LMS's volume control back on, so a
/// switch from a fixed DAC to another lands right. LyrionPlay owns the pref: a change made in LMS
/// or Material is put back at the next check. Setting it makes LMS send a new audg at once
/// (Player.pm's setChange, LMS 9.1).
public struct FixedVolumeSync: Sendable {
	private struct Want: Equatable, Sendable {
		var device: String
		var value: Int
	}

	/// a value LMS did not take, for that device
	private var refused: Want?

	public init() {}

	public static func value(for mode: VolumeMode) -> Int { mode == .fixed ? 0 : 1 }

	/// One LMS check of a connected player. `device`: the UID the engine plays to; `lms`: the pref
	/// as `status` gave it (nil: not said, so nothing is sent). nil: send nothing.
	public mutating func checked(device: String, mode: VolumeMode, lms: Int?) -> [String]? {
		guard let lms else { return nil }
		let want = Want(device: device, value: Self.value(for: mode))
		if lms == want.value {
			refused = nil
			return nil
		}
		if refused == want { return nil }
		return ["playerpref", "digitalVolumeControl", String(want.value)]
	}

	/// LMS's change hook for this pref, `$client->volume($client->volume)` (Player.pm:77, LMS 9.1),
	/// saves the player's TEMPORARY volume as its real one: a pause fades it to a temporary 0
	/// (`_Pause`, `fade_volume`), and a switch from a fixed DAC then left LMS at volume 0 (measured
	/// 2026-10-11: 50 became 0). `before`/`after`: the saved volume (`mixer volume ?`) around the send.
	/// The command that puts it back, or nil. A muted player keeps a negative volume, which the hook
	/// does not change (its `mute` pref stops the clamp), and `mixer volume -N` would be relative, so
	/// a negative volume is never put back.
	public static func volumeRestore(before: Double?, after: Double?) -> [String]? {
		guard let before, before >= 0, let after, after != before else { return nil }
		let level = before == before.rounded() ? String(Int(before)) : String(before)
		return ["mixer", "volume", level]
	}

	/// The pref as LMS gave it straight after a send. true: LMS did not take the value, and the
	/// refusal is recorded, so say it, once: it is not sent again until the device or its mode
	/// changes, so a refusal is not a loop. (LMS refuses 0 from a player without HasDigitalOut,
	/// Player.pm's validator; the engine always sends HasDigitalOut=1, so this guards a case not seen.)
	/// Was `sent(…)`, which read as "true: sent" (/code-review 2026-10-12 (3), finding 4).
	public mutating func recordRefusal(device: String, mode: VolumeMode, lmsAfter: Int?) -> Bool {
		let want = Want(device: device, value: Self.value(for: mode))
		guard let lmsAfter, lmsAfter != want.value else { return false }
		refused = want
		return true
	}
}
