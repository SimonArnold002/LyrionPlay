import Foundation

/// What the agent reports to the app, through status.json: what is shared, and one entry per
/// player whose engine runs or should (ONE PLAYER PER DAC).
public struct AgentStatus: Codable, Equatable, Sendable {
	public var updated: Date
	public var agentPID: Int32
	public var devices: [DeviceCaps]
	public var serverName: String?
	/// the server the agent talks to, so the app can ask it for a player's volume (HeldVolume)
	public var serverHost: String?
	public var serverWebPort: Int?
	/// a problem of the whole player, in plain words (the engine missing from the app)
	public var problem: String?
	public var players: [PlayerStatus]

	public init(agentPID: Int32) {
		updated = Date()
		self.agentPID = agentPID
		devices = []
		players = []
	}

	public func player(_ key: String) -> PlayerStatus? { players.first { $0.key == key } }

	/// a status from before players (0.3.x) loads with none
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		updated = try c.decode(Date.self, forKey: .updated)
		agentPID = try c.decode(Int32.self, forKey: .agentPID)
		devices = try c.decodeIfPresent([DeviceCaps].self, forKey: .devices) ?? []
		serverName = try c.decodeIfPresent(String.self, forKey: .serverName)
		serverHost = try c.decodeIfPresent(String.self, forKey: .serverHost)
		serverWebPort = try c.decodeIfPresent(Int.self, forKey: .serverWebPort)
		problem = try c.decodeIfPresent(String.self, forKey: .problem)
		players = try c.decodeIfPresent([PlayerStatus].self, forKey: .players) ?? []
	}

	public static func load(from url: URL = Paths.status) -> AgentStatus? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try? decoder.decode(AgentStatus.self, from: data)
	}

	public func save(to url: URL = Paths.status) throws {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(self).write(to: url, options: .atomic)
	}
}

/// One player, as the menu panel shows it.
public struct PlayerStatus: Codable, Equatable, Sendable {
	public var key: String
	public var name: String
	/// its LMS player ID; nil for a player that is on but whose identity could not be made (its
	/// problem says why). Never "": that is LMS's request for no player (LMSClient.call), so a reader
	/// passing it on would ask the server, not fail (/code-review 2026-10-15 (8) finding 5)
	public var mac: String?
	public var engineRunning: Bool
	public var enginePID: Int32?
	public var deviceUID: String?
	public var deviceName: String?
	/// the device's real state, read from CoreAudio
	public var currentRate: Int?
	public var currentFormat: String?
	/// DSD played as DoP: its rate (16 x currentRate), from the engine's report (FormatReport)
	public var dsdRate: Int?
	public var exclusive: Bool
	public var connected: Bool
	public var mode: String?
	public var nowPlaying: String?
	/// the latest problem, in plain words
	public var problem: String?

	public init(key: String, name: String, mac: String?) {
		self.key = key
		self.name = name
		self.mac = mac
		engineRunning = false
		exclusive = false
		connected = false
	}

	/// The menu's first line for the player, its connection to LMS. None for a player with no
	/// identity: it has no engine and never connects, so "Connecting…" was false (/code-review
	/// 2026-10-15 (8) finding 3); its problem line says why.
	public func serverLine(serverName: String?) -> String? {
		guard mac != nil else { return nil }
		if connected { return "Connected to \(serverName ?? "LMS")" }
		if let serverName { return "Connecting to \(serverName)…" }
		return "Looking for the server…"
	}
}
