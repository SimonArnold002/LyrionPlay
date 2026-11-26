import Foundation
import Testing
@testable import PlayerCore

/// The update notice (ledger UPDATE NOTICE): GitHub's latest release against this build's version
@Suite struct UpdateCheckTests {
	/// GitHub's reply for the latest release, cut down from the real one of 2026-11-26
	static func reply(tag: String) -> Data {
		Data("""
		{"url":"https://api.github.com/repos/SimonArnold002/LyrionPlay/releases/1",
		 "html_url":"https://github.com/SimonArnold002/LyrionPlay/releases/tag/\(tag)",
		 "tag_name":"\(tag)","name":"LyrionPlay","draft":false,"prerelease":false,
		 "assets":[{"name":"LyrionPlay-0.5.3.zip","size":1740750,
		   "digest":"sha256:be901a2a44cf295a4eb0d88fc2a2f50398f390ce3dcebc50f18d7bd0b10fb640",
		   "browser_download_url":"https://github.com/SimonArnold002/LyrionPlay/releases/download/v0.5.3/LyrionPlay-0.5.3.zip"}]}
		""".utf8)
	}

	@Test func theReplyGivesTheTagsVersion() {
		#expect(UpdateCheck.version(fromReply: Self.reply(tag: "v0.5.3")) == "0.5.3")
		#expect(UpdateCheck.version(fromReply: Self.reply(tag: "0.6.0")) == "0.6.0")
	}

	/// a tag that is not plain numbers, a reply without one, and no JSON at all show nothing
	@Test func anythingElseGivesNoVersion() {
		for tag in ["v0.6.0-beta", "v", "", "latest", "v0..1", "v1.2.", "v+1.2", "v1.٣"] {
			#expect(UpdateCheck.version(fromReply: Self.reply(tag: tag)) == nil, "tag \(tag)")
		}
		#expect(UpdateCheck.version(fromReply: Data(#"{"message":"Not Found"}"#.utf8)) == nil)
		#expect(UpdateCheck.version(fromReply: Data(#"{"tag_name":5}"#.utf8)) == nil)
		#expect(UpdateCheck.version(fromReply: Data("<html>rate limited</html>".utf8)) == nil)
	}

	@Test func aLaterVersionIsNewer() {
		#expect(UpdateCheck.isNewer("0.5.4", than: "0.5.3"))
		#expect(UpdateCheck.isNewer("0.6.0", than: "0.5.9"))
		#expect(UpdateCheck.isNewer("1.0", than: "0.9.99"))
		// numbers, not text: "0.5.10" sorts before "0.5.9" as text
		#expect(UpdateCheck.isNewer("0.5.10", than: "0.5.9"))
		#expect(UpdateCheck.isNewer("0.5.3.1", than: "0.5.3"))
	}

	@Test func theSameOrAnEarlierVersionIsNot() {
		#expect(!UpdateCheck.isNewer("0.5.3", than: "0.5.3"))
		#expect(!UpdateCheck.isNewer("0.5.3.0", than: "0.5.3"))
		#expect(!UpdateCheck.isNewer("0.5.3", than: "0.5.3.0"))
		#expect(!UpdateCheck.isNewer("0.5.2", than: "0.5.3"))
		#expect(!UpdateCheck.isNewer("0.5.9", than: "0.5.10"))
		#expect(!UpdateCheck.isNewer("0.4.15", than: "0.5.3"))
	}

	/// a build with no version from its Info.plist ("dev") is never told about one
	@Test func aBuildWithoutAVersionIsNeverOffered() {
		#expect(!UpdateCheck.isNewer("9.9.9", than: "dev"))
		#expect(!UpdateCheck.isNewer("dev", than: "0.5.3"))
	}

	typealias Notice = UpdateCheck.Notice
	static let sent = Date(timeIntervalSince1970: 1_800_000_000)
	static let earlier = sent - 2 * 24 * 3600

	/// a check sent at `sent`, answered with `status` and a reply with `tag` (no reply when nil)
	static func after(_ notice: Notice, _ status: Int?, _ tag: String?, current: String = "0.5.3") -> Notice {
		UpdateCheck.after(notice, sent: sent, status: status, reply: tag.map { reply(tag: $0) }, current: current)
	}

	/// a failed request changes nothing: one GitHub error must not hide a notice the user saw, nor count as
	/// an answer, which would put the next try off for a day
	@Test func aFailedCheckChangesNothing() {
		for before in [Notice(available: "0.5.4", lastAnswered: Self.earlier), Notice()] {
			#expect(Self.after(before, nil, nil) == before)
			for status in [403, 404, 500, 503] {
				#expect(Self.after(before, status, "v0.5.5") == before, "status \(status)")
			}
			#expect(Self.after(before, 200, nil) == before)
		}
		// so the next tick tries again
		#expect(UpdateCheck.isDue(Self.after(Notice(), 503, "v0.5.5"), now: Self.sent + UpdateCheck.tick))
	}

	/// an answer is stamped with the time its check was sent
	@Test func anAnswerReplacesTheNotice() {
		let before = Notice(available: "0.5.4", lastAnswered: Self.earlier)
		#expect(Self.after(Notice(), 200, "v0.5.4") == Notice(available: "0.5.4", lastAnswered: Self.sent))
		#expect(Self.after(before, 200, "v0.5.5") == Notice(available: "0.5.5", lastAnswered: Self.sent))
		// the same or an earlier version clears it (installed meanwhile, or a release withdrawn)
		#expect(Self.after(before, 200, "v0.5.3") == Notice(available: nil, lastAnswered: Self.sent))
		#expect(Self.after(before, 200, "v0.5.2") == Notice(available: nil, lastAnswered: Self.sent))
		// a dev build is never told
		#expect(Self.after(Notice(), 200, "v0.5.4", current: "dev") == Notice(available: nil, lastAnswered: Self.sent))
	}

	/// a tag that does not read clears an earlier notice: the link opens whatever release is latest
	@Test func anUnreadableTagClearsTheNotice() {
		let before = Notice(available: "0.5.4", lastAnswered: Self.earlier)
		#expect(Self.after(before, 200, "v0.6.0-rc1") == Notice(available: nil, lastAnswered: Self.sent))
		let empty = UpdateCheck.after(before, sent: Self.sent, status: 200, reply: Data("{}".utf8), current: "0.5.3")
		#expect(empty == Notice(available: nil, lastAnswered: Self.sent))
	}

	/// once a day on the wall clock, sleep included, half a tick early allowed; a clock set back does not
	/// stop the checks
	@Test func aCheckIsDueOnceADay() {
		let answered = Notice(lastAnswered: Self.sent)
		let day = UpdateCheck.interval, tick = UpdateCheck.tick
		#expect(day == 24 * 3600 && tick == 3600)
		#expect(UpdateCheck.isDue(Notice(), now: Self.sent))
		#expect(!UpdateCheck.isDue(answered, now: Self.sent))
		#expect(!UpdateCheck.isDue(answered, now: Self.sent + day - tick))
		#expect(!UpdateCheck.isDue(answered, now: Self.sent + day - tick / 2 - 1))
		#expect(UpdateCheck.isDue(answered, now: Self.sent + day - tick / 2))
		#expect(UpdateCheck.isDue(answered, now: Self.sent + day - 0.3))
		#expect(UpdateCheck.isDue(answered, now: Self.sent + day))
		#expect(UpdateCheck.isDue(answered, now: Self.sent + 3 * day))
		#expect(UpdateCheck.isDue(answered, now: Self.sent - 60))
	}

	/// hourly ticks that each fire a little late, by a different amount, check once a day: never every
	/// 25 h (/code-review 2026-11-26 (2), finding 1), never twice in one day
	@Test func hourlyTicksCheckOnceADay() {
		var notice = Notice()
		var checks: [Int] = []
		for hour in 0 ... 72 {
			let now = Self.sent + Double(hour) * UpdateCheck.tick + Double(hour % 5) * 0.3
			guard UpdateCheck.isDue(notice, now: now) else { continue }
			checks.append(hour)
			notice = UpdateCheck.after(notice, sent: now, status: 200, reply: Self.reply(tag: "v0.5.3"), current: "0.5.3")
		}
		#expect(checks == [0, 24, 48, 72])
	}

	@Test func theLinksAreTheRepositorysOwn() {
		#expect(UpdateCheck.latestAPI.absoluteString == "https://api.github.com/repos/SimonArnold002/LyrionPlay/releases/latest")
		#expect(UpdateCheck.releasePage.absoluteString == "https://github.com/SimonArnold002/LyrionPlay/releases/latest")
	}
}
