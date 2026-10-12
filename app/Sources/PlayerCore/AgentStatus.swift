import Foundation

/// What the agent reports to the app, through status.json.
public struct AgentStatus: Codable, Equatable, Sendable {
	public var updated: Date
	public var agentPID: Int32
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
	public var serverName: String?
	public var connected: Bool
	public var mode: String?
	public var nowPlaying: String?
	public var devices: [DeviceCaps]
	/// the latest problem, in plain words
	public var problem: String?

	public init(agentPID: Int32) {
		updated = Date()
		self.agentPID = agentPID
		engineRunning = false
		exclusive = false
		connected = false
		devices = []
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
