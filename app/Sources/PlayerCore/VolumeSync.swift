import Foundation

/// One `lyrionplay:volume <dB> <muted> <lms>` line from the engine (output_coreaudio.c,
/// volume_listener): the Mac's volume keys or menu bar slider moved the device.
public struct VolumeReport: Equatable, Sendable {
	/// LMS's last `audg`, as the engine got it
	public enum LMSLevel: Int, Sendable {
		/// none yet: LMS sends one only when a track starts, so whether its volume is fixed is not
		/// known either
		case unknown = -1
		/// silence: LMS is muted, or at volume 0
		case silent = 0
		/// a level, so LMS is not muted
		case audible = 1
	}

	public var dB: Double
	public var muted: Bool
	public var lms: LMSLevel

	public init(dB: Double, muted: Bool, lms: LMSLevel) {
		self.dB = dB
		self.muted = muted
		self.lms = lms
	}

	/// nil for any other line. A line without <lms> counts as unknown, so the agent asks LMS.
	public init?(line: some StringProtocol) {
		let fields = line.split(separator: " ")
		guard fields.count == 3 || fields.count == 4, fields[0] == "lyrionplay:volume",
			  let dB = Double(fields[1]), fields[2] == "0" || fields[2] == "1" else { return nil }
		self.dB = dB
		muted = fields[2] == "1"
		lms = fields.count == 4 ? Int(fields[3]).flatMap(LMSLevel.init(rawValue:)) ?? .unknown : .unknown
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
		// Unmuting on the Mac while LMS is muted asks LMS to unmute, so it fades back to the
		// volume it kept. A level would be wrong: LMS faded the device to its minimum when it
		// muted (measured 2026-10-09: unmute gave LMS volume 7 instead of 42; UNMUTE IS NOT A
		// LEVEL). LMS stores a muted volume as a negative number. A report of LMS at a level
		// needs no question: LMS is not muted.
		if report.lms != .audible, let current = await lmsVolume(), current < 0 {
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
