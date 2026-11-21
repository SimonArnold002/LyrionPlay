import Foundation
import Testing
@testable import PlayerCore

/// macOS Now Playing (themmm/LyrionPlay#1): which Player's Current track fills the one system-wide
/// slot, as a shared setting (Settings > Shared)
@Suite struct NowPlayingSetting {
	/// settings carry over from 0.4.0 on: a file without the key takes the default
	@Test func aFileWithoutTheKeyTakesTheMostRecentPlayer() throws {
		let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"version":2,"server":"plex"}"#.utf8))
		#expect(settings.nowPlaying == .mostRecent)
		#expect(Settings().nowPlaying == .mostRecent)
	}

	@Test func eachChoiceRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrionplay-settings-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: url) }
		for choice in [NowPlayingChoice.off, .mostRecent, .player(PlayerKey.follow), .player(fiio.uid)] {
			var settings = Settings()
			settings.nowPlaying = choice
			try settings.save(to: url)
			#expect(Settings.load(from: url).nowPlaying == choice)
		}
	}
}

let followMAC = "02:00:4c:4d:50:01", dacMAC = "02:00:4c:4d:50:02"
let nowPlayingServer = LMSServer(host: "plex", webPort: 9000, name: "Simons Music")

/// a status as LMS sends it on a `status - 1 tags:…` subscription (Queries.pm statusQuery, LMS 9.1):
/// JSON text, so numbers and strings arrive as they would
func lmsStatus(_ json: String) -> LMSPlayerStatus {
	LMSPlayerStatus(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
}

/// a local track playing (or paused, stopped) on a connected player
func localTrack(_ mode: String = "play", time: Double = 12.5, title: String = "Hold On", connected: Int = 1) -> LMSPlayerStatus {
	lmsStatus("""
		{"player_name":"Study","player_connected":\(connected),"power":1,"mode":"\(mode)","time":\(time),"rate":1,
		 "duration":215.4,"can_seek":1,"playlist_tracks":10,"playlist_cur_index":"2",
		 "playlist_loop":[{"playlist index":2,"id":816519,"title":"\(title)","artist":"The Roots",
		   "album":"Things Fall Apart","coverid":"a1b2c3d4","duration":215.4}]}
		""")
}

func players(_ list: (String, String, Bool)...) -> [NowPlayingPlayer] {
	list.map { NowPlayingPlayer(key: $0.0, mac: $0.1, on: $0.2) }
}

let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite struct NowPlayingSlot {
	@Test func aPlayingPlayerFillsTheSlotWithItsTrack() {
		var np = NowPlaying(server: nowPlayingServer, players: players((PlayerKey.follow, followMAC, true)), choice: .mostRecent)
		np.status(localTrack(time: 12.5), of: followMAC, at: t0)
		let info = np.shown(at: t0.addingTimeInterval(2))
		#expect(info?.player == PlayerKey.follow)
		#expect(info?.mac == followMAC)
		#expect(info?.title == "Hold On")
		#expect(info?.artist == "The Roots")
		#expect(info?.album == "Things Fall Apart")
		#expect(info?.duration == 215.4)
		#expect(info?.playing == true)
		#expect(info?.isLiveStream == false)
		#expect(info?.canSeek == true)
		// LMS's time when the status came, running on while it plays
		#expect(info?.elapsed(at: t0.addingTimeInterval(2)) == 14.5)
	}

	/// decision 8: paused stays, shown as paused, its time standing
	@Test func aPausedPlayerKeepsTheSlotShownPaused() {
		var np = NowPlaying(server: nowPlayingServer, players: players((PlayerKey.follow, followMAC, true)), choice: .mostRecent)
		np.status(localTrack(time: 38), of: followMAC, at: t0.addingTimeInterval(-2))
		np.status(localTrack("pause", time: 40), of: followMAC, at: t0)
		let info = np.shown(at: t0.addingTimeInterval(30))
		#expect(info?.title == "Hold On")
		#expect(info?.playing == false)
		#expect(info?.elapsed(at: t0.addingTimeInterval(30)) == 40)
	}

	/// decision 8: stop, the Player switched off, or the Player disconnected from LMS free it at once
	@Test func stopSwitchOffAndDisconnectFreeTheSlotAtOnce() {
		var np = NowPlaying(server: nowPlayingServer, players: players((PlayerKey.follow, followMAC, true)), choice: .mostRecent)
		np.status(localTrack(), of: followMAC, at: t0)
		#expect(np.shown(at: t0) != nil)
		np.status(localTrack("stop"), of: followMAC, at: t0.addingTimeInterval(1))
		#expect(np.shown(at: t0.addingTimeInterval(1)) == nil)

		np.status(localTrack(), of: followMAC, at: t0.addingTimeInterval(2))
		np.status(localTrack(connected: 0), of: followMAC, at: t0.addingTimeInterval(3))
		#expect(np.shown(at: t0.addingTimeInterval(3)) == nil)

		// switched off in LyrionPlay: freed before LMS sees the engine go
		np.status(localTrack(), of: followMAC, at: t0.addingTimeInterval(4))
		#expect(np.shown(at: t0.addingTimeInterval(4)) != nil)
		np.update(players: players((PlayerKey.follow, followMAC, false)), choice: .mostRecent)
		#expect(np.shown(at: t0.addingTimeInterval(4)) == nil)
	}

	/// a player LMS forgot, or that never connected to this server: its last status no longer counts
	@Test func aPlayerLMSNoLongerListsFreesTheSlot() {
		var np = NowPlaying(server: nowPlayingServer, players: players((PlayerKey.follow, followMAC, true)), choice: .mostRecent)
		np.serverStatus(listing(followMAC), at: t0)
		np.status(localTrack(), of: followMAC, at: t0)
		#expect(np.shown(at: t0) != nil)
		np.serverStatus(listing(), at: t0.addingTimeInterval(1))
		#expect(np.shown(at: t0.addingTimeInterval(1)) == nil)
	}
}

/// a `serverstatus` as LMS sends it (Queries.pm _addPlayersLoop): the players it knows, connected
func listing(_ macs: String..., connected: Int = 1) -> LMSServerStatus {
	let loop = macs.map { #"{"playerid":"\#($0.uppercased())","name":"x","connected":\#(connected),"isplaying":0,"power":1}"# }
	return LMSServerStatus(try! JSONSerialization.jsonObject(with: Data(#"{"player count":\#(macs.count),"players_loop":[\#(loop.joined(separator: ","))]}"#.utf8)) as! [String: Any])
}


/// decision 7's default: the Player that most recently started playing wins; when it stops, another
/// one still playing takes over
@Suite struct NowPlayingMostRecent {
	let both = players((PlayerKey.follow, followMAC, true), (fiio.uid, dacMAC, true))
	func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

	@Test func theLaterStartWinsAndAPausedHolderStays() {
		var np = NowPlaying(server: nowPlayingServer, players: both, choice: .mostRecent)
		np.status(localTrack(title: "Follow"), of: followMAC, at: at(0))
		#expect(np.shown(at: at(0))?.player == PlayerKey.follow)
		np.status(localTrack(title: "DAC"), of: dacMAC, at: at(1))
		#expect(np.shown(at: at(1))?.title == "DAC")
		np.status(localTrack("pause", title: "DAC"), of: dacMAC, at: at(2))
		#expect(np.shown(at: at(2))?.title == "DAC")
		#expect(np.shown(at: at(2))?.playing == false)
		// the other's next track is no new start
		np.status(localTrack(time: 0, title: "Follow 2"), of: followMAC, at: at(3))
		#expect(np.shown(at: at(3))?.title == "DAC")
		np.status(localTrack("stop", title: "DAC"), of: dacMAC, at: at(4))
		#expect(np.shown(at: at(4))?.title == "Follow 2")
	}

	@Test func aResumeIsAStart() {
		var np = NowPlaying(server: nowPlayingServer, players: both, choice: .mostRecent)
		np.status(localTrack(title: "Follow"), of: followMAC, at: at(0))
		np.status(localTrack(title: "DAC"), of: dacMAC, at: at(1))
		np.status(localTrack("pause", title: "Follow"), of: followMAC, at: at(2))
		#expect(np.shown(at: at(2))?.title == "DAC")
		np.status(localTrack(title: "Follow"), of: followMAC, at: at(3))
		#expect(np.shown(at: at(3))?.title == "Follow")
	}

	@Test func onlyAPlayingPlayerTakesOver() {
		var np = NowPlaying(server: nowPlayingServer, players: both, choice: .mostRecent)
		np.status(localTrack(title: "Follow"), of: followMAC, at: at(0))
		np.status(localTrack(title: "DAC"), of: dacMAC, at: at(1))
		np.status(localTrack("pause", title: "Follow"), of: followMAC, at: at(2))
		np.status(localTrack("stop", title: "DAC"), of: dacMAC, at: at(3))
		#expect(np.shown(at: at(3)) == nil)
		// Follow, paused, is not shown until it plays again
		np.status(localTrack("pause", title: "Follow"), of: followMAC, at: at(4))
		#expect(np.shown(at: at(4)) == nil)
		np.status(localTrack(title: "Follow"), of: followMAC, at: at(5))
		#expect(np.shown(at: at(5))?.title == "Follow")
	}
}

/// decision 7: Off, or one Player chosen by name
@Suite struct NowPlayingChosen {
	let both = players((PlayerKey.follow, followMAC, true), (fiio.uid, dacMAC, true))
	func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

	@Test func offShowsNothing() {
		var np = NowPlaying(server: nowPlayingServer, players: both, choice: .off)
		np.status(localTrack(), of: followMAC, at: at(0))
		#expect(np.shown(at: at(0)) == nil)
		// and back on: the Player playing fills it at once
		np.update(players: both, choice: .mostRecent)
		#expect(np.shown(at: at(0))?.player == PlayerKey.follow)
	}

	/// the chosen Player only, while it plays or is paused; the slot is free otherwise
	@Test func aChosenPlayerHoldsTheSlotWhilePlayingOrPaused() {
		var np = NowPlaying(server: nowPlayingServer, players: both, choice: .player(fiio.uid))
		np.status(localTrack(title: "Follow"), of: followMAC, at: at(0))
		#expect(np.shown(at: at(0)) == nil)
		np.status(localTrack("pause", title: "DAC"), of: dacMAC, at: at(1))
		#expect(np.shown(at: at(1))?.title == "DAC")
		np.status(localTrack(title: "Follow"), of: followMAC, at: at(2))
		np.status(localTrack(title: "DAC"), of: dacMAC, at: at(3))
		np.status(localTrack("pause", title: "Follow"), of: followMAC, at: at(4))
		np.status(localTrack(title: "Follow"), of: followMAC, at: at(5))
		#expect(np.shown(at: at(5))?.title == "DAC")
		np.status(localTrack("stop", title: "DAC"), of: dacMAC, at: at(6))
		#expect(np.shown(at: at(6)) == nil)
	}

	/// a chosen Player that was removed: the default rule
	@Test func aRemovedChoiceFallsBackToTheMostRecent() {
		var np = NowPlaying(server: nowPlayingServer, players: both, choice: .player("AppleUSBAudioEngine:gone"))
		np.status(localTrack(title: "Follow"), of: followMAC, at: at(0))
		np.status(localTrack(title: "DAC"), of: dacMAC, at: at(1))
		#expect(np.shown(at: at(1))?.title == "DAC")
	}
}

/// decision 5: a radio stream shows what LMS reports (station, current song, artwork), with no
/// duration, progress or seek. A remote track with a length (a streaming service) is a track.
@Suite struct NowPlayingStreams {
	let follow = players((PlayerKey.follow, followMAC, true))

	/// LMS for a radio station: remote, the station as `remote_title` (tag N) and `current_title`,
	/// the song in the track's title and artist, no duration, no can_seek
	let radio = lmsStatus("""
		{"player_connected":1,"power":1,"mode":"play","time":312.8,"rate":1,"remote":1,
		 "current_title":"Radio Paradise - Main Mix","playlist_tracks":1,
		 "playlist_loop":[{"playlist index":0,"id":-94563472,"title":"Teardrop","artist":"Massive Attack",
		   "remote_title":"Radio Paradise - Main Mix","remote":1,"artwork_url":"https://img.radioparadise.com/covers/l/B000002UJQ.jpg"}]}
		""")

	@Test func aRadioStreamHasNoLengthProgressOrSeek() {
		var np = NowPlaying(server: nowPlayingServer, players: follow, choice: .mostRecent)
		np.status(radio, of: followMAC, at: t0)
		let info = np.shown(at: t0)
		#expect(info?.title == "Teardrop")
		#expect(info?.artist == "Massive Attack")
		#expect(info?.album == "Radio Paradise - Main Mix")
		#expect(info?.isLiveStream == true)
		#expect(info?.duration == nil)
		#expect(info?.elapsed(at: t0) == nil)
		#expect(info?.canSeek == false)
	}

	/// a station that sends no song: the station is the title
	@Test func aStationWithoutASongIsItsOwnTitle() {
		var np = NowPlaying(server: nowPlayingServer, players: follow, choice: .mostRecent)
		np.status(lmsStatus("""
			{"player_connected":1,"mode":"play","time":3,"remote":1,"current_title":"BBC Radio 3",
			 "playlist_loop":[{"title":"","remote_title":"BBC Radio 3","remote":1}]}
			"""), of: followMAC, at: t0)
		#expect(np.shown(at: t0)?.title == "BBC Radio 3")
		#expect(np.shown(at: t0)?.album == nil)
	}

	@Test func aRemoteTrackWithALengthIsATrack() {
		var np = NowPlaying(server: nowPlayingServer, players: follow, choice: .mostRecent)
		np.status(lmsStatus("""
			{"player_connected":1,"mode":"play","time":20,"remote":1,"duration":241,"can_seek":1,
			 "current_title":"Qobuz","playlist_loop":[{"title":"Tomorrow Never Knows","artist":"The Beatles",
			   "album":"Revolver","remote":1,"duration":241}]}
			"""), of: followMAC, at: t0)
		let info = np.shown(at: t0)
		#expect(info?.isLiveStream == false)
		#expect(info?.duration == 241)
		#expect(info?.album == "Revolver")
		#expect(info?.canSeek == true)
		#expect(info?.elapsed(at: t0) == 20)
	}
}

/// decision 2: artwork from LMS. A library track by its cover ID, resized by LMS (Web/Graphics.pm
/// `WxH` spec); a remote image through LMS's image proxy (Web/ImageProxy.pm proxiedImage); a path
/// on the server under the server
@Suite struct NowPlayingArtwork {
	let follow = players((PlayerKey.follow, followMAC, true))

	func artwork(_ track: String, remote: Bool = false) -> String? {
		var np = NowPlaying(server: nowPlayingServer, players: follow, choice: .mostRecent)
		np.status(lmsStatus("""
			{"player_connected":1,"mode":"play","time":1,\(remote ? #""remote":1,"# : #""duration":100,"#)
			 "playlist_loop":[{"title":"T",\(track)}]}
			"""), of: followMAC, at: t0)
		return np.shown(at: t0)?.artwork?.absoluteString
	}

	@Test func aLibraryTrackByItsCoverID() {
		#expect(artwork(#""coverid":"a1b2c3d4""#) == "http://plex:9000/music/a1b2c3d4/cover_600x600.jpg")
	}

	@Test func aRemoteImageThroughLMSsProxy() {
		#expect(artwork(#""artwork_url":"https://img.radioparadise.com/covers/l/B000002UJQ.jpg""#, remote: true)
				== "http://plex:9000/imageproxy/https%3A%2F%2Fimg.radioparadise.com%2Fcovers%2Fl%2FB000002UJQ.jpg/image_600x600.jpg")
	}

	@Test func aPathOnTheServer() {
		#expect(artwork(#""artwork_url":"plugins/TuneIn/html/images/icon.png""#, remote: true)
				== "http://plex:9000/plugins/TuneIn/html/images/icon.png")
		#expect(artwork(#""artwork_url":"/imageproxy/x/image.png""#, remote: true) == "http://plex:9000/imageproxy/x/image.png")
	}

	/// a remote track's own image before a cover ID LMS made for it
	@Test func aRemoteTrackPrefersItsImage() {
		#expect(artwork(#""coverid":"-123","artwork_url":"https://a.b/c.jpg""#, remote: true)
				== "http://plex:9000/imageproxy/https%3A%2F%2Fa.b%2Fc.jpg/image_600x600.jpg")
	}

	@Test func noImageNoArtwork() {
		#expect(artwork(#""artist":"A""#) == nil)
	}
}

/// decision 8: a lost subscription keeps the last state while it reconnects, and frees the slot if it
/// has not reconnected within 5 s
@Suite struct NowPlayingGrace {
	func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
	func playing() -> NowPlaying {
		var np = NowPlaying(server: nowPlayingServer, players: players((PlayerKey.follow, followMAC, true)), choice: .mostRecent)
		np.status(localTrack(time: 10), of: followMAC, at: at(0))
		return np
	}

	@Test func theLastStateStaysForFiveSeconds() {
		var np = playing()
		np.lost(at: at(1))
		#expect(abs((np.shown(at: at(5.9))?.elapsed(at: at(5.9)) ?? 0) - 15.9) < 0.001)
		#expect(np.shown(at: at(6)) == nil)
		// a later failure while still lost does not move the deadline
		np.lost(at: at(4))
		#expect(np.shown(at: at(6)) == nil)
	}

	@Test func reconnectedInTimeKeepsTheSlot() {
		var np = playing()
		np.lost(at: at(1))
		np.restored(at: at(3))
		#expect(np.shown(at: at(30))?.title == "Hold On")
		// and the next loss has its own 5 s
		np.lost(at: at(40))
		#expect(np.shown(at: at(44))?.title == "Hold On")
		#expect(np.shown(at: at(45)) == nil)
	}

	/// reconnected after the slot was freed: the old state is not shown again; LMS sends each
	/// Player's status again on the new subscription
	@Test func reconnectedLateWaitsForLMSToResend() {
		var np = playing()
		np.lost(at: at(1))
		#expect(np.shown(at: at(10)) == nil)
		np.restored(at: at(10))
		#expect(np.shown(at: at(10)) == nil)
		np.status(localTrack(time: 20), of: followMAC, at: at(10.1))
		#expect(np.shown(at: at(10.1))?.elapsed(at: at(10.1)) == 20)
	}
}

/// decisions 3 and 4: what the notch, Control Center and the media keys send, as LMS commands for
/// the Player in the slot (Commands.pm playcontrolCommand, timeCommand; Buttons/Common.pm `jump`)
@Suite struct NowPlayingCommands {
	func shown(_ status: LMSPlayerStatus) -> NowPlayingInfo {
		var np = NowPlaying(server: nowPlayingServer, players: players((PlayerKey.follow, followMAC, true)), choice: .mostRecent)
		np.status(status, of: followMAC, at: t0)
		return np.shown(at: t0)!
	}

	@Test func eachCommandForTheShownPlayer() {
		let track = shown(localTrack())
		#expect(RemoteCommand.togglePlayPause.lms(for: track) == ["pause"])
		#expect(RemoteCommand.play.lms(for: track) == ["pause", "0"])
		#expect(RemoteCommand.pause.lms(for: track) == ["pause", "1"])
		#expect(RemoteCommand.next.lms(for: track) == ["playlist", "index", "+1"])
		// LMS's own Back button: it restarts the song after 5 s, else goes to the one before
		#expect(RemoteCommand.previous.lms(for: track) == ["button", "jump_rew"])
		#expect(RemoteCommand.seek(83.25).lms(for: track) == ["time", "83.250"])
		#expect(RemoteCommand.seek(-1).lms(for: track) == ["time", "0.000"])
	}

	/// the notch sends a seek to 0 s on a live stream although seeking is disabled (prototype,
	/// 2026-11-21): refused here, or the radio would restart
	@Test func noSeekOnAStreamOrATrackLMSCannotSeek() {
		let radio = shown(lmsStatus("""
			{"player_connected":1,"mode":"play","time":30,"remote":1,"can_seek":1,
			 "playlist_loop":[{"title":"Teardrop","remote":1}]}
			"""))
		#expect(RemoteCommand.seek(0).lms(for: radio) == nil)
		#expect(RemoteCommand.togglePlayPause.lms(for: radio) == ["pause"])
		let unseekable = shown(lmsStatus("""
			{"player_connected":1,"mode":"play","time":30,"duration":200,
			 "playlist_loop":[{"title":"T","duration":200}]}
			"""))
		#expect(RemoteCommand.seek(10).lms(for: unseekable) == nil)
	}
}

/// LMS's cometd end as a script (Web/Cometd.pm, LMS 9.1): it hands out a client ID at the handshake,
/// answers each /slim/subscribe with its data at once (long-polling) and each /meta/connect with what
/// the test queued. Every request is kept, decoded, with the timeout it was sent with.
actor ScriptedCometd: CometdTransport {
	var clientID = "1a2b3c4d"
	var requests: [(messages: [[String: Any]], timeout: TimeInterval)] = []
	/// what the next connect returns besides its own answer
	var queued: [[String: Any]] = []
	/// the next post fails this way instead
	var failNext: Error?
	/// the next connect is refused with LMS's advice to handshake again (an unknown client ID)
	var forgetClientNext = false
	/// each player's status, as its subscription answers
	var statuses: [String: String] = [:]
	var serverStatus = #"{"players_loop":[]}"#

	func post(_ body: Data, timeout: TimeInterval) async throws -> Data {
		let messages = try JSONSerialization.jsonObject(with: body) as! [[String: Any]]
		requests.append((messages, timeout))
		if let failNext { self.failNext = nil; throw failNext }
		var answer: [[String: Any]] = []
		for m in messages {
			switch m["channel"] as! String {
			case "/meta/handshake":
				answer.append(["channel": "/meta/handshake", "clientId": clientID, "successful": true,
							   "advice": ["reconnect": "retry", "interval": 0, "timeout": 60000]])
			case "/meta/connect":
				if forgetClientNext || m["clientId"] as? String != clientID {
					forgetClientNext = false
					answer.append(["channel": "/meta/connect", "successful": false, "error": "invalid clientId",
								   "advice": ["reconnect": "handshake", "interval": 0]])
					continue
				}
				answer.insert(["channel": "/meta/connect", "clientId": clientID, "successful": true], at: 0)
				answer += queued
				queued = []
			case "/slim/subscribe":
				let data = m["data"] as! [String: Any]
				let request = data["request"] as! [Any]
				let player = request[0] as! String
				let json = player.isEmpty ? serverStatus : statuses[player] ?? #"{"mode":"stop"}"#
				answer.append(["channel": "/slim/subscribe", "clientId": clientID, "successful": true, "id": m["id"] ?? 0])
				answer.append(["channel": data["response"] as! String, "id": m["id"] ?? 0,
							   "data": try JSONSerialization.jsonObject(with: Data(json.utf8))])
			default:
				break
			}
		}
		return try JSONSerialization.data(withJSONObject: answer)
	}

	func set(_ change: (ScriptedCometd) -> Void) { change(self) }
	func setServerStatus(_ json: String) { serverStatus = json }
	func setStatus(_ json: String, of mac: String) { statuses[mac] = json }
	func queue(_ channel: String, _ json: String) {
		queued.append(["channel": "/\(clientID)/slim/\(channel)", "data": try! JSONSerialization.jsonObject(with: Data(json.utf8))])
	}
	func fail(_ error: Error) { failNext = error }
	func forgetClient(newID: String) { forgetClientNext = true; clientID = newID }
	/// the /slim/subscribe requests of the last post, as "player command…"
	func lastSubscribes() -> [String] {
		(requests.last?.messages ?? []).filter { $0["channel"] as? String == "/slim/subscribe" }.map {
			let request = ($0["data"] as! [String: Any])["request"] as! [Any]
			return ([request[0] as! String] + (request[1] as! [String])).joined(separator: " ")
		}
	}
	func last() -> (messages: [[String: Any]], timeout: TimeInterval)? { requests.last }
}

func serverListing(_ macs: String...) -> String {
	#"{"players_loop":[\#(macs.map { #"{"playerid":"\#($0)","connected":1}"# }.joined(separator: ","))]}"#
}

let statusRequest = "status - 1 tags:acdKlNx subscribe:30"

/// decision 6: the menu app subscribes to LMS itself over cometd, as Material does; a lost or hung
/// subscription is reported, for the 5 s grace (decision 8)
@Suite struct NowPlayingFeedOverCometd {
	@Test func itSubscribesToTheServerThenToEachOfItsPlayersLMSLists() async throws {
		let lms = ScriptedCometd()
		await lms.setServerStatus(serverListing(followMAC, "aa:bb:cc:dd:ee:ff"))
		await lms.setStatus(#"{"player_connected":1,"mode":"play","time":5,"playlist_loop":[{"title":"Hold On"}]}"#, of: followMAC)
		let feed = LMSFeed(transport: lms, players: [followMAC, dacMAC])

		let first = await feed.poll()
		#expect(first.first == .restored)
		#expect(first.contains(.serverStatus(LMSServerStatus(["players_loop": [["playerid": followMAC, "connected": 1], ["playerid": "aa:bb:cc:dd:ee:ff", "connected": 1]]]))))
		#expect(await lms.lastSubscribes() == [" serverstatus 0 100 subscribe:60"])

		// only its own Players that LMS knows: an unknown player's subscribe is an error that stops
		// LMS's processing of the rest of the request (Cometd.pm errorNeedClient)
		let second = await feed.poll()
		#expect(await lms.lastSubscribes() == ["\(followMAC) \(statusRequest)"])
		guard case .status(let mac, let status) = second.last else { Issue.record("no status: \(second)"); return }
		#expect(mac == followMAC)
		#expect(status.title == "Hold On")
		#expect(!second.contains(.restored))

		// each poll waits at most 10 s in LMS, and is given up 5 s after that: a silent hang is a loss
		let poll = await lms.last()!
		let connect = poll.messages.first { $0["channel"] as? String == "/meta/connect" }!
		#expect((connect["advice"] as? [String: Any])?["timeout"] as? Int == 10_000)
		#expect(connect["connectionType"] as? String == "long-polling")
		#expect(poll.timeout == 15)

		// nothing new to subscribe: only the poll
		await lms.queue("playerstatus/\(followMAC)", #"{"player_connected":1,"mode":"pause","time":9}"#)
		let third = await feed.poll()
		#expect(await lms.lastSubscribes() == [])
		guard case .status(_, let paused) = third.last else { Issue.record("no status: \(third)"); return }
		#expect(paused.mode == "pause")
	}

	@Test func aFailedPollIsALossAndTheNextGoodOneRestoresIt() async {
		let lms = ScriptedCometd()
		await lms.setServerStatus(serverListing(followMAC))
		let feed = LMSFeed(transport: lms, players: [followMAC])
		_ = await feed.poll()
		_ = await feed.poll()
		await lms.fail(URLError(.timedOut))
		#expect(await feed.poll() == [.lost])
		#expect(await feed.poll() == [.restored])
		// LMS kept the client: nothing to subscribe again
		#expect(await lms.lastSubscribes() == [])
	}

	/// LMS forgot the client (restarted, or no poll for 3 minutes): it advises a new handshake, and
	/// every subscription is made again under the new client ID
	@Test func aForgottenClientHandshakesAndSubscribesAgain() async {
		let lms = ScriptedCometd()
		await lms.setServerStatus(serverListing(followMAC))
		let feed = LMSFeed(transport: lms, players: [followMAC])
		_ = await feed.poll()
		_ = await feed.poll()
		await lms.forgetClient(newID: "99887766")
		#expect(await feed.poll() == [.lost])
		let again = await feed.poll()
		#expect(again.first == .restored)
		#expect(await lms.lastSubscribes() == [" serverstatus 0 100 subscribe:60"])
		_ = await feed.poll()
		#expect(await lms.lastSubscribes() == ["\(followMAC) \(statusRequest)"])
		let responses = (await lms.last()!.messages).compactMap { ($0["data"] as? [String: Any])?["response"] as? String }
		#expect(responses == ["/99887766/slim/playerstatus/\(followMAC)"])
	}

	/// a Player LMS forgot and that comes back has a new subscription (LMS drops the old one)
	@Test func aPlayerListedAgainIsSubscribedAgain() async {
		let lms = ScriptedCometd()
		await lms.setServerStatus(serverListing(followMAC))
		let feed = LMSFeed(transport: lms, players: [followMAC])
		_ = await feed.poll()
		_ = await feed.poll()
		await lms.queue("serverstatus", serverListing())
		_ = await feed.poll()
		#expect(await lms.lastSubscribes() == [])
		await lms.queue("serverstatus", serverListing(followMAC))
		_ = await feed.poll()
		_ = await feed.poll()
		#expect(await lms.lastSubscribes() == ["\(followMAC) \(statusRequest)"])
	}

	/// a Player switched on later, or a new one: subscribed at the next poll once LMS lists it
	@Test func aPlayerAddedLaterIsSubscribed() async {
		let lms = ScriptedCometd()
		await lms.setServerStatus(serverListing(followMAC, dacMAC))
		let feed = LMSFeed(transport: lms, players: [followMAC])
		_ = await feed.poll()
		_ = await feed.poll()
		await feed.setPlayers([followMAC, dacMAC])
		_ = await feed.poll()
		#expect(await lms.lastSubscribes() == ["\(dacMAC) \(statusRequest)"])
	}
}

/// the Players Now Playing knows: from settings.json, each with the MAC its folder holds
@Suite struct NowPlayingPlayers {
	@Test func everySavedPlayerWithAnIdentity() {
		var settings = Settings()
		settings.players[fiio.uid] = player(fiio, enabled: false, volume: .software)
		settings.players[dragonfly.uid] = player(dragonfly, volume: .device)
		let macs = [PlayerKey.follow: followMAC, fiio.uid: dacMAC]
		let list = NowPlaying.players(in: settings) { macs[$0] }
		// the DragonFly never ran: no MAC, so LMS cannot know it
		#expect(list == [NowPlayingPlayer(key: PlayerKey.follow, mac: followMAC, on: true),
						 NowPlayingPlayer(key: fiio.uid, mac: dacMAC, on: false)])
	}

	/// Follow is a Player even before settings.json names it (on by default)
	@Test func followWithoutSavedSettings() {
		var settings = Settings()
		settings.players = [:]
		#expect(NowPlaying.players(in: settings) { _ in followMAC } == [NowPlayingPlayer(key: PlayerKey.follow, mac: followMAC, on: true)])
	}
}
