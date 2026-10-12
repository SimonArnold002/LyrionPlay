import Foundation

public struct LMSServer: Equatable, Sendable {
	public var host: String
	public var webPort: Int
	public var name: String?

	public init(host: String, webPort: Int, name: String?) {
		self.host = host
		self.webPort = webPort
		self.name = name
	}
}

/// The server the agent talks to, for the status and the Mac's volume pushes (the engine is told
/// the setting itself, `-s`), and what that server last said of this player. A server that answers
/// is reused without looking at the setting again, so a check that began before the setting
/// changed must not bring the old server back: LMS can stall for seconds, longer than the agent's
/// 2 s tick, and such a check would win for good. Nor may the old server's word on the player
/// outlive a change (connected, mode and now playing in the menu).
public struct ServerChoice: Sendable {
	public private(set) var server: LMSServer?
	/// what `server` said of this player at the last check; nil when none answered
	public private(set) var playerState: LMSClient.PlayerState?
	/// the server setting as last saved: "" finds one on the network
	public private(set) var setting: String

	public init(setting: String) { self.setting = setting }

	/// the setting was saved; a different one forgets the server and what it said. True if it
	/// changed: the agent then checks the new one at once, not at its 5 s cadence.
	@discardableResult
	public mutating func update(setting: String) -> Bool {
		guard setting != self.setting else { return false }
		server = nil
		playerState = nil
		self.setting = setting
		return true
	}

	/// a check that began with `setting` ended: `found` nil means no server answered. False, and
	/// nothing kept, if the setting changed meanwhile; the agent then checks the new one at once.
	@discardableResult
	public mutating func checked(setting: String, found: LMSServer?, state: LMSClient.PlayerState? = nil) -> Bool {
		guard setting == self.setting else { return false }
		server = found
		playerState = found == nil ? nil : state
		return true
	}

	/// the agent is stopping: nothing is known of the player any more
	public mutating func forgetPlayer() { playerState = nil }
}

/// What agent.log says of the agent's LMS checks. A stalled server can't be staged on the rig, so
/// these lines are how one is seen (A STALLED SERVER IS NOT A FINDING), never a line per check: the
/// first slow check of a run and the run's end, and the server the agent uses, each time it changes
/// and at the first check after the agent starts or the server setting changes.
/// A check is slow when the server took over 2 s to answer it (the players and status requests):
/// the agent's tick, which a check outlasting is the stall rule's case. Discovery's own wait (2 s
/// when nothing replies) is not the server's time. A request no one answers times out at 4 s, so a
/// server that has gone is one slow line and one "did not answer". LMS answers in ~30 ms on the rig.
/// Until /code-review 2026-10-11 (3) the whole check was timed against 4 s, the request's own
/// timeout: only a request that got no answer could cross it, never a late answer.
public struct LMSCheckLog: Sendable {
	/// over this, the server's answer is slow
	public static let slowAnswer: TimeInterval = 2

	/// what the last "LMS:" line said the agent uses
	private enum Said: Equatable, Sendable {
		case nothing                // no line yet since the agent started or the setting changed
		case server(LMSServer?)     // that server; nil: none
	}
	private var said = Said.nothing

	/// a run of slow answers, all from one server
	private struct Run: Sendable {
		var server: LMSServer
		var count: Int
		var slowest: TimeInterval
	}
	private var run: Run?

	public init() {}

	/// the server setting changed: the next check says which server it found, whatever it is, and a
	/// run of slow checks ends unsaid (its end would name the new server)
	public mutating func settingChanged() {
		said = .nothing
		run = nil
	}

	public static func describe(_ server: LMSServer?) -> String {
		server.map { "\($0.name ?? $0.host) (\($0.host):\($0.webPort))" } ?? "no server"
	}

	/// each end carries the one time its lines print
	public enum End: Sendable {
		/// kept: the agent now uses the server checked if it answered, none if not. `answer` is how
		/// long that server took over the players and status requests (nil: no server to ask)
		case kept(answered: Bool, answer: TimeInterval?)
		/// dropped: begun with server setting `began`, which is now `now`. `took` is the whole check,
		/// discovery included
		case dropped(began: String, now: String, took: TimeInterval)
	}

	/// the lines for a check of `found` (nil: none found). A dropped check is one line, with its
	/// time, and is no part of a run: it checked a setting no longer in force.
	public mutating func ended(_ end: End, found: LMSServer?) -> [String] {
		switch end {
		case .dropped(let began, let now, let took):
			return ["LMS check of \(Self.describe(found)) dropped after \(String(format: "%.1f", took)) s: begun with server setting \"\(began)\", now \"\(now)\""]
		case .kept(let answered, let answer):
			return [timed(answer, of: found), uses(answered ? found : nil, found: found)].compactMap { $0 }
		}
	}

	private mutating func timed(_ answer: TimeInterval?, of found: LMSServer?) -> String? {
		// a run is one server's: a check of another, or of none, ends it unsaid, as a setting change
		// does (a server gone, then a discovery that finds none, ended it as "checks of no server")
		if let current = run, current.server != found { run = nil }
		guard let found, let answer else { return nil }
		if answer > Self.slowAnswer {
			if var current = run {
				current.count += 1
				current.slowest = max(current.slowest, answer)
				run = current
				return nil
			}
			run = Run(server: found, count: 1, slowest: answer)
			return "LMS check of \(Self.describe(found)) took \(String(format: "%.1f", answer)) s"
		}
		guard let ended = run else { return nil }
		run = nil
		// under 2 s, not "answering": a run can end in a quick failure (LMS restarting refuses at once)
		return "LMS checks of \(Self.describe(found)) back under 2 s (\(String(format: "%.2f", answer)) s), after \(ended.count) slower, the slowest \(String(format: "%.1f", ended.slowest)) s"
	}

	private mutating func uses(_ server: LMSServer?, found: LMSServer?) -> String? {
		if said == .server(server) { return nil }
		said = .server(server)
		guard let server else {
			return "LMS: \(found == nil ? "no server found" : "\(Self.describe(found)) did not answer")"
		}
		return "LMS: using \(Self.describe(server))"
	}
}

/// LMS's UDP discovery (Slim::Networking::Discovery): 'e' plus TLV requests to port 3483, answered
/// with 'E' plus TLVs (4-byte tag, 1-byte length, value). Broadcast to find a server, or sent to
/// one host to learn its name and web port.
public enum LMSDiscovery {
	public static func find(host: String? = nil, timeout: TimeInterval = 2) -> LMSServer? {
		let fd = socket(AF_INET, SOCK_DGRAM, 0)
		guard fd >= 0 else { return nil }
		defer { close(fd) }
		var on: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
		var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

		var to = sockaddr_in()
		to.sin_family = sa_family_t(AF_INET)
		to.sin_port = in_port_t(3483).bigEndian
		if let host {
			guard let ip = resolveIPv4(host) else { return nil }
			to.sin_addr = ip
		} else {
			to.sin_addr.s_addr = INADDR_BROADCAST
		}

		let request: [UInt8] = Array("e".utf8) + tlv("NAME") + tlv("JSON")
		let sent = withUnsafePointer(to: &to) { ptr in
			ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				sendto(fd, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		guard sent == request.count else { return nil }

		var reply = [UInt8](repeating: 0, count: 512)
		var from = sockaddr_in()
		var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
		let n = withUnsafeMutablePointer(to: &from) { ptr in
			ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &reply, reply.count, 0, $0, &fromLength) }
		}
		guard n > 0, reply[0] == UInt8(ascii: "E") else { return nil }

		var fields = [String: String]()
		var i = 1
		while i + 5 <= n {
			let tag = String(decoding: reply[i..<i + 4], as: UTF8.self)
			let length = Int(reply[i + 4])
			guard i + 5 + length <= n else { break }
			fields[tag] = String(decoding: reply[(i + 5)..<(i + 5 + length)], as: UTF8.self)
			i += 5 + length
		}
		var address = from.sin_addr
		var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
		inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN))
		let ip = String(cString: text)
		return LMSServer(host: host ?? ip, webPort: Int(fields["JSON"] ?? "") ?? 9000, name: fields["NAME"])
	}

	static func tlv(_ tag: String) -> [UInt8] { Array(tag.utf8) + [0] }

	static func resolveIPv4(_ host: String) -> in_addr? {
		var hints = addrinfo()
		hints.ai_family = AF_INET
		hints.ai_socktype = SOCK_DGRAM
		var result: UnsafeMutablePointer<addrinfo>?
		guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
		defer { freeaddrinfo(result) }
		return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
	}
}

/// LMS JSON-RPC (POST /jsonrpc.js), for the status line.
public struct LMSClient: Sendable {
	public var server: LMSServer

	public init(server: LMSServer) { self.server = server }

	public func call(player: String, _ command: [String]) async -> [String: Any]? {
		guard let url = URL(string: "http://\(server.host):\(server.webPort)/jsonrpc.js") else { return nil }
		var request = URLRequest(url: url, timeoutInterval: 4)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		let body: [String: Any] = ["id": 1, "method": "slim.request", "params": [player, command]]
		request.httpBody = try? JSONSerialization.data(withJSONObject: body)
		guard let (data, _) = try? await URLSession.shared.data(for: request),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
		return json["result"] as? [String: Any]
	}

	/// `mixer volume ?`: the SAVED volume (`mixerQuery` reads the pref, LMS 9.1), never the temporary
	/// one a fade sets. LMS keeps a muted player's volume as a negative number
	public func volume(player: String) async -> Double? {
		guard let result = await call(player: player, ["mixer", "volume", "?"]) else { return nil }
		return Double("\(result["_volume"] ?? "")")
	}

	/// `playerpref digitalVolumeControl ?`: 0 is "Output level fixed at 100%". LMS sends this pref
	/// as audg's adjust byte (Squeezebox2::volume, LMS 9.1), and defaults it to 1.
	public func digitalVolumeControl(player: String) async -> Int? {
		guard let result = await call(player: player, ["playerpref", "digitalVolumeControl", "?"]),
			  let value = result["_p2"] else { return nil }
		return Int("\(value)")
	}

	public func volumeFixed(player: String) async -> Bool? {
		await digitalVolumeControl(player: player).map { $0 == 0 }
	}

	public struct PlayerState: Sendable {
		public var connected: Bool
		public var mode: String?
		public var nowPlaying: String?
		/// the player's `digitalVolumeControl` pref, 0 = "Output level fixed at 100%"; nil when
		/// `status` did not say
		public var digitalVolumeControl: Int?

		/// `status` carries the pref as `digital_volume_control`, an integer (Queries.pm, LMS 9.1;
		/// measured on the rig 2026-10-11)
		static func digitalVolumeControl(in status: [String: Any]) -> Int? {
			status["digital_volume_control"].flatMap { Int("\($0)") }
		}
	}

	public func playerState(mac: String) async -> PlayerState? {
		guard let players = await call(player: "", ["players", "0", "99"]) else { return nil }
		let loop = players["players_loop"] as? [[String: Any]] ?? []
		guard let me = loop.first(where: { ($0["playerid"] as? String)?.lowercased() == mac }) else {
			return PlayerState(connected: false)
		}
		var state = PlayerState(connected: (me["connected"] as? Int ?? 0) == 1)
		if let status = await call(player: mac, ["status", "-", "1", "tags:a"]) {
			state.mode = status["mode"] as? String
			state.digitalVolumeControl = PlayerState.digitalVolumeControl(in: status)
			if let track = (status["playlist_loop"] as? [[String: Any]])?.first {
				let title = track["title"] as? String ?? ""
				let artist = track["artist"] as? String
				state.nowPlaying = artist.map { "\(title) — \($0)" } ?? title
			}
		}
		return state
	}
}
