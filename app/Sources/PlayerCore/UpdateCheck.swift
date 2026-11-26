import Foundation

/// The update notice (ledger UPDATE NOTICE): the menu app asks GitHub for the latest release and,
/// when it is newer than this build, links to its page. Nothing is downloaded or installed.
public enum UpdateCheck {
	/// the latest release; GitHub leaves out drafts and pre-releases
	public static let latestAPI = URL(string: "https://api.github.com/repos/SimonArnold002/LyrionPlay/releases/latest")!
	/// the page the menu links to: the release's notes and its zip
	public static let releasePage = URL(string: "https://github.com/SimonArnold002/LyrionPlay/releases/latest")!

	/// how long an answered check holds, on the wall clock
	public static let interval: TimeInterval = 24 * 3600
	/// how often the menu app asks `isDue`: a Timer counts only the time the Mac is awake, so a 24 h one
	/// fired every few days on a Mac that sleeps (/code-review 2026-11-26, finding 1)
	public static let tick: TimeInterval = 3600

	/// what the menu app keeps between checks
	public struct Notice: Equatable, Sendable {
		/// the newer release's version, while there is one
		public var available: String?
		/// when the last check GitHub answered (200) was sent
		public var lastAnswered: Date?

		public init(available: String? = nil, lastAnswered: Date? = nil) {
			self.available = available
			self.lastAnswered = lastAnswered
		}
	}

	/// A check is due when none has been answered yet, when `interval` has passed since the last answered
	/// one, or when the clock was set back before it. Half a tick early counts, so a tick a moment short of
	/// the day does not put the check off to the next one (/code-review 2026-11-26 (2), finding 1).
	public static func isDue(_ notice: Notice, now: Date) -> Bool {
		guard let last = notice.lastAnswered else { return true }
		let elapsed = now.timeIntervalSince(last)
		return elapsed >= interval - tick / 2 || elapsed < 0
	}

	/// The notice after a check sent at `sent`. A failed request (no answer, or not 200) changes nothing,
	/// so the next tick tries again. An answer stamps `sent` and replaces what the menu shows: the release's
	/// version while it is newer than `current`, else nothing, also for a tag that does not read, since the
	/// link opens whatever release is latest (/code-review 2026-11-26, finding 2).
	public static func after(_ notice: Notice, sent: Date, status: Int?, reply: Data?, current: String) -> Notice {
		guard status == 200, let reply else { return notice }
		var latest = version(fromReply: reply)
		if let version = latest, !isNewer(version, than: current) { latest = nil }
		return Notice(available: latest, lastAnswered: sent)
	}

	/// the release's version in GitHub's reply ("v0.5.4" gives "0.5.4"); nil for anything else
	public static func version(fromReply data: Data) -> String? {
		struct Reply: Decodable { let tag_name: String }
		guard let tag = try? JSONDecoder().decode(Reply.self, from: data).tag_name else { return nil }
		let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
		return parts(version) == nil ? nil : version
	}

	/// `candidate` is a later version than `current`; false when either is not plain numbers ("dev")
	public static func isNewer(_ candidate: String, than current: String) -> Bool {
		guard let new = parts(candidate), let old = parts(current) else { return false }
		for i in 0 ..< max(new.count, old.count) {
			let a = i < new.count ? new[i] : 0, b = i < old.count ? old[i] : 0
			if a != b { return a > b }
		}
		return false
	}

	/// "0.5.10" gives [0, 5, 10]; nil unless every part is digits only
	static func parts(_ version: String) -> [Int]? {
		let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
		var numbers: [Int] = []
		for piece in pieces {
			guard !piece.isEmpty, piece.allSatisfy({ ("0" ... "9").contains($0) }), let n = Int(piece) else { return nil }
			numbers.append(n)
		}
		return numbers
	}
}
