import Foundation

/// Which Player's Current track fills macOS Now Playing: none, the
/// Player that most recently started playing (the default), or one Player, by its key
/// (`PlayerKey.follow` or a device UID). Stored as one string: "off", "recent", or the key.
public enum NowPlayingChoice: Hashable, Sendable, Codable {
	case off
	case mostRecent
	case player(String)

	public init(from decoder: Decoder) throws {
		let text = try decoder.singleValueContainer().decode(String.self)
		switch text {
		case "off": self = .off
		case "recent": self = .mostRecent
		default: self = .player(text)
		}
	}

	/// what the choice means with these settings: one of a Player no longer saved (removed, or a device
	/// never set up) is the default it falls back to, as the Settings picker shows it
	public func effective(in settings: Settings) -> NowPlayingChoice {
		if case .player(let key) = self, !NowPlaying.playerKeys(in: settings).contains(key) { return .mostRecent }
		return self
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.singleValueContainer()
		switch self {
		case .off: try c.encode("off")
		case .mostRecent: try c.encode("recent")
		case .player(let key): try c.encode(key)
		}
	}
}

/// One LMS `status` of a player, as its cometd subscription delivers it (Queries.pm statusQuery,
/// LMS 9.1), reduced to what Now Playing shows. LMS writes numbers as numbers or strings; both read.
public struct LMSPlayerStatus: Equatable, Sendable {
	public var connected: Bool
	/// "play", "pause" or "stop" (LMS says stop for a player switched off in LMS)
	public var mode: String
	/// LMS's song time when it answered
	public var time: Double?
	public var duration: Double?
	public var canSeek: Bool
	public var title: String?
	public var artist: String?
	public var album: String?
	/// a remote URL (radio, a streaming service), not a file of the library
	public var remote: Bool
	/// a remote stream's own name: the station (tag N `remote_title`, else `current_title`)
	public var station: String?

	/// tag c: a library track's cover, served by LMS
	public var coverID: String?
	/// tag K: a remote track's image, a URL or a path on the server
	public var artworkURL: String?

	/// a stream with no length (radio): no progress and no seek, whatever else LMS says
	public var isLiveStream: Bool { remote && (duration ?? 0) <= 0 }

	public init(_ json: [String: Any]) {
		connected = Self.number(json["player_connected"]) == 1
		mode = json["mode"] as? String ?? "stop"
		time = Self.number(json["time"])
		duration = Self.number(json["duration"])
		canSeek = Self.number(json["can_seek"]) == 1
		let track = (json["playlist_loop"] as? [[String: Any]])?.first ?? [:]
		title = Self.text(track["title"])
		artist = Self.text(track["artist"])
		album = Self.text(track["album"])
		remote = Self.number(json["remote"]) == 1
		station = Self.text(track["remote_title"]) ?? Self.text(json["current_title"])
		coverID = Self.text(track["coverid"])
		artworkURL = Self.text(track["artwork_url"])
	}

	/// The image LMS serves for the track, 600 px square: a remote track's own image first (through
	/// LMS's image proxy when it is elsewhere, Web/ImageProxy.pm proxiedImage), else the cover ID
	/// (`/music/<id>/cover_WxH`, Web/Graphics.pm).
	func artwork(on server: LMSServer) -> URL? {
		let base = "http://\(server.host):\(server.webPort)"
		let image = remote ? artworkURL ?? coverID.map { "/music/\($0)/cover_600x600.jpg" }
			: coverID.map { "/music/\($0)/cover_600x600.jpg" } ?? artworkURL
		guard let image else { return nil }
		if image.hasPrefix("http://") || image.hasPrefix("https://") {
			// uri_escape_utf8: all but the unreserved characters
			var unreserved = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: "\u{0}"..."\u{7F}"))
			unreserved.insert(charactersIn: "-._~")
			guard let escaped = image.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
			return URL(string: "\(base)/imageproxy/\(escaped)/image_600x600.jpg")
		}
		return URL(string: base + (image.hasPrefix("/") ? image : "/" + image))
	}

	static func number(_ value: Any?) -> Double? {
		guard let value else { return nil }
		return Double("\(value)")
	}

	static func text(_ value: Any?) -> String? {
		guard let text = value.map({ "\($0)" }), !text.isEmpty else { return nil }
		return text
	}
}

/// One LMS `serverstatus` (Queries.pm _addPlayersLoop, LMS 9.1): the players it knows, by lowercase
/// MAC, and whether each is connected. LMS pushes it at once when a player is forgotten.
public struct LMSServerStatus: Equatable, Sendable {
	public var players: [String: Bool]

	public init(_ json: [String: Any]) {
		var players: [String: Bool] = [:]
		for player in json["players_loop"] as? [[String: Any]] ?? [] {
			guard let id = player["playerid"] as? String else { continue }
			players[id.lowercased()] = LMSPlayerStatus.number(player["connected"]) == 1
		}
		self.players = players
	}
}

/// A LyrionPlay Player as Now Playing sees it: its key, its LMS ID, and whether it is switched on
public struct NowPlayingPlayer: Equatable, Sendable {
	public var key: String
	/// nil for a Player that never ran: LMS cannot know it
	public var mac: String?
	public var on: Bool

	/// the MAC as LMS's channels and answers are matched: lowercase
	var id: String? { mac?.lowercased() }

	public init(key: String, mac: String?, on: Bool) {
		self.key = key
		self.mac = mac
		self.on = on
	}
}

/// What macOS Now Playing shows, for one Player's Current track
public struct NowPlayingInfo: Equatable, Sendable {
	public var player: String
	public var mac: String
	public var title: String
	public var artist: String?
	public var album: String?
	public var artwork: URL?
	public var duration: Double?
	public var playing: Bool
	public var isLiveStream: Bool
	public var canSeek: Bool
	/// LMS's song time at `elapsedAt`
	public var elapsed: Double?
	public var elapsedAt: Date

	/// a Player's status as Now Playing shows it. A radio stream: the song as title and artist, the
	/// station as album (as the title when no song is sent), no duration, time or seek
	init(player: String, mac: String, status: LMSPlayerStatus, at time: Date, server: LMSServer) {
		self.player = player
		artwork = status.artwork(on: server)
		self.mac = mac
		playing = status.mode == "play"
		elapsedAt = time
		artist = status.artist
		isLiveStream = status.isLiveStream
		if isLiveStream {
			title = status.title ?? status.station ?? ""
			album = status.album ?? (status.title == nil ? nil : status.station)
			duration = nil
			elapsed = nil
			canSeek = false
		} else {
			title = status.title ?? ""
			album = status.album
			duration = status.duration
			elapsed = status.time
			canSeek = status.canSeek
		}
	}

	/// the song time at `now`: running on while it plays
	public func elapsed(at now: Date) -> Double? {
		guard let elapsed else { return nil }
		return playing ? elapsed + now.timeIntervalSince(elapsedAt) : elapsed
	}
}

/// Which Player fills macOS Now Playing, and with what. Fed with each Player's
/// LMS status as the cometd subscription delivers it; `shown(at:)` is what to publish, nil to free it.
public struct NowPlaying: Sendable {
	public let server: LMSServer
	public private(set) var players: [NowPlayingPlayer]
	public private(set) var choice: NowPlayingChoice
	private var statuses: [String: (status: LMSPlayerStatus, at: Date)] = [:]
	/// what LMS's last serverstatus listed; nil before the first
	private var listed: LMSServerStatus?
	/// when each player last went into play (a resume counts; a next track does not), by lowercase MAC
	private var started: [String: Date] = [:]
	/// the lowercase MAC of the Player in the slot
	private var holder: String?
	/// when the subscription was lost, while it is
	private var lostAt: Date?

	/// how long a lost subscription keeps the slot
	public static let grace: TimeInterval = 5

	public init(server: LMSServer, players: [NowPlayingPlayer], choice: NowPlayingChoice) {
		self.server = server
		self.players = players
		self.choice = choice
	}

	/// LyrionPlay's Players, as the Settings picker offers them: *Follow the macOS output*, then each
	/// saved device player by name. A device never saved is no Player yet.
	public static func playerKeys(in settings: Settings) -> [String] {
		let saved = settings.players.filter { $0.key != PlayerKey.follow }
		return [PlayerKey.follow] + saved.keys.sorted { (saved[$0]!.name, $0) < (saved[$1]!.name, $1) }
	}

	/// Each Player with the MAC its folder holds (`mac`: `PlayerIdentity.mac(at: Paths.mac(key))`); nil
	/// for one that never ran. A switched-off Player, or one that never ran, stays listed: a fixed
	/// choice of it frees the slot; only a removed one falls back to the default.
	public static func players(in settings: Settings, mac: (String) -> String?) -> [NowPlayingPlayer] {
		playerKeys(in: settings).map { NowPlayingPlayer(key: $0, mac: mac($0), on: settings.isOn($0)) }
	}

	/// the Players (from settings.json and their identities) or the shared setting changed
	public mutating func update(players: [NowPlayingPlayer], choice: NowPlayingChoice) {
		self.players = players
		self.choice = choice
		reselect()
	}

	public mutating func status(_ status: LMSPlayerStatus, of mac: String, at time: Date) {
		let mac = mac.lowercased()
		if status.mode == "play", statuses[mac]?.status.mode != "play" { started[mac] = time }
		statuses[mac] = (status, time)
		reselect()
	}

	public mutating func serverStatus(_ status: LMSServerStatus, at time: Date) {
		listed = status
		reselect()
	}

	/// the subscription failed (an error, LMS's advice to handshake again, a poll that hung): the last
	/// state stands for `grace`, from the first failure, while it reconnects
	public mutating func lost(at time: Date) {
		if lostAt == nil { lostAt = time }
	}

	/// subscribed again. After the grace, what LMS said before is stale: nothing is shown until it
	/// sends each Player's status again (it does, on each new subscription)
	public mutating func restored(at time: Date) {
		if let lostAt, time.timeIntervalSince(lostAt) >= Self.grace {
			statuses = [:]
			listed = nil
			reselect()
		}
		lostAt = nil
	}

	/// The holder keeps the slot while it plays or is paused; a Player that starts playing later takes
	/// it; when the holder is freed, the Player still playing that started last takes over, or none.
	private mutating func reselect() {
		switch choice {
		case .off:
			holder = nil
			return
		case .player(let key):
			// a chosen Player that was removed falls back to the default rule
			if let chosen = players.first(where: { $0.key == key }) {
				holder = current(chosen) == nil ? nil : chosen.id
				return
			}
		case .mostRecent:
			break
		}
		let playing = players.filter { current($0)?.status.mode == "play" }.compactMap(\.id)
		let latest = playing.max { (started[$0] ?? .distantPast) < (started[$1] ?? .distantPast) }
		if let holder, players.contains(where: { $0.id == holder && current($0) != nil }) {
			if let latest, (started[latest] ?? .distantPast) > (started[holder] ?? .distantPast) { self.holder = latest }
		} else {
			holder = latest
		}
	}

	/// playing or paused, connected, listed by LMS, and switched on in LyrionPlay
	private func current(_ player: NowPlayingPlayer) -> (status: LMSPlayerStatus, at: Date)? {
		guard player.on, let mac = player.id, let entry = statuses[mac], entry.status.connected,
			  entry.status.mode == "play" || entry.status.mode == "pause" else { return nil }
		if let listed, listed.players[mac] != true { return nil }
		return entry
	}

	public func shown(at now: Date) -> NowPlayingInfo? {
		if let lostAt, now.timeIntervalSince(lostAt) >= Self.grace { return nil }
		for player in players where player.id == holder {
			guard let (status, at) = current(player), let mac = player.mac else { continue }
			return NowPlayingInfo(player: player.key, mac: mac, status: status, at: at, server: server)
		}
		return nil
	}
}

/// What macOS Now Playing sends (Control Center, the media keys, other Now Playing apps;
/// MPRemoteCommandCenter), as an LMS command for the Player in the slot.
public enum RemoteCommand: Equatable, Sendable {
	case play, pause, togglePlayPause, next, previous
	case seek(Double)

	/// nil: nothing to send. A seek on a live stream or a track LMS cannot seek is refused (`canSeek` is
	/// false for every live stream): a third-party Now Playing app was seen sending one (to 0 s) even
	/// with seeking disabled, and a radio would restart.
	public func lms(for info: NowPlayingInfo) -> [String]? {
		switch self {
		// playcontrolCommand (Commands.pm, LMS 9.1): `pause` toggles, `pause 0` plays, `pause 1` pauses
		case .togglePlayPause: return ["pause"]
		case .play: return ["pause", "0"]
		case .pause: return ["pause", "1"]
		case .next: return ["playlist", "index", "+1"]
		// LMS's own Back button (Buttons/Common.pm `jump` with `rew`): under 5 s into the song, or
		// stopped, the song before; else this one from the start. LMS decides, on its own song time
		case .previous: return ["button", "jump_rew"]
		case .seek(let time):
			guard info.canSeek else { return nil }
			return ["time", String(format: "%.3f", max(0, time))]
		}
	}
}
