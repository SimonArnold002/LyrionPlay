import Foundation

/// One POST of Bayeux messages to LMS's /cometd, answered with Bayeux messages. `timeout` bounds the
/// wait for an answer, so a poll that hangs without a word fails.
public protocol CometdTransport: Sendable {
	func post(_ body: Data, timeout: TimeInterval) async throws -> Data
}

/// LMS's /cometd over HTTP, as Material reaches it
public struct HTTPCometd: CometdTransport {
	public let url: URL

	public init?(server: LMSServer) {
		guard let url = URL(string: "http://\(server.host):\(server.webPort)/cometd") else { return nil }
		self.url = url
	}

	public func post(_ body: Data, timeout: TimeInterval) async throws -> Data {
		// the timeout is URLSession's wait for the next byte: LMS sends nothing while a poll waits, so a
		// silent hang ends here
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = body
		let (data, response) = try await URLSession.shared.data(for: request)
		guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
		return data
	}
}

/// The menu app's own subscription to LMS for Now Playing, over
/// cometd long-polling as Material does (Web/Cometd.pm, LMS 9.1): `serverstatus`, for the players LMS
/// knows, and `status` of each of LyrionPlay's Players it lists. Only listed ones: a subscribe for a
/// player LMS does not know is an error that stops LMS's processing of the rest of that request
/// (`errorNeedClient`). Every subscribe goes in the next poll's request, so there is one request at a
/// time. `poll()` is one round trip; `run` repeats it.
public actor LMSFeed {
	public enum Event: Equatable, Sendable {
		/// subscribed and answering again, after a failure (or for the first time)
		case restored
		/// a poll failed, hung, or LMS forgot this client: the grace starts (NowPlaying.lost)
		case lost
		case serverStatus(LMSServerStatus)
		/// a Player's status, by lowercase MAC
		case status(String, LMSPlayerStatus)
	}

	/// how long LMS holds a poll open with nothing to say (`advice.timeout` on /meta/connect; LMS's own
	/// default is 60 s), and how much longer an answer may take before the poll counts as hung
	public static let pollWait: TimeInterval = 10
	public static let pollMargin: TimeInterval = 5
	/// LMS re-sends a status at least this often on its own, besides on each change
	static let statusRequest = ["status", "-", "1", "tags:acdKlNx", "subscribe:30"]
	static let serverStatusRequest = ["serverstatus", "0", "100", "subscribe:60"]

	private let transport: CometdTransport
	/// LyrionPlay's Players, by lowercase MAC
	private var players: Set<String>
	private var clientID: String?
	private var serverSubscribed = false
	/// the players LMS's last serverstatus listed, and those subscribed under this client ID
	private var listed: Set<String> = []
	private var subscribed: Set<String> = []
	private var healthy = false
	private var nextID = 1

	public init(transport: CometdTransport, players: [String]) {
		self.transport = transport
		self.players = Set(players.map { $0.lowercased() })
	}

	/// the Players changed (one switched on, added or removed): a new one is subscribed at the next poll
	public func setPlayers(_ macs: [String]) {
		players = Set(macs.map { $0.lowercased() })
	}

	/// One round trip: a handshake first when there is no client ID, then a long-poll carrying every
	/// subscribe still to make.
	public func poll() async -> [Event] {
		do {
			return try await roundTrip()
		} catch {
			let wasHealthy = healthy
			healthy = false
			// subscribe everything again at the next good poll, so LMS sends the current state at once:
			// after the grace NowPlaying drops what it had, and LMS says nothing more of a track that
			// plays on unchanged until its 30 s resend. A repeat replaces LMS's
			// earlier subscription (Request.pm registerAutoExecute: one per client ID, command and player)
			serverSubscribed = false
			subscribed = []
			return wasHealthy ? [.lost] : []
		}
	}

	/// polls until cancelled, handing each poll's events on; after a failure it waits 1, 2, 4, then 5 s
	/// between tries, so it tries twice within the 5 s grace
	public func run(deliver: @Sendable ([Event]) async -> Void) async {
		var failures = 0
		while !Task.isCancelled {
			let events = await poll()
			await deliver(events)
			if healthy {
				failures = 0
			} else {
				failures += 1
				try? await Task.sleep(for: .seconds(min(5, 1 << min(failures - 1, 3))))
			}
		}
	}

	private struct Failure: Error {}

	private func roundTrip() async throws -> [Event] {
		if clientID == nil {
			let reply = try await send([["channel": "/meta/handshake", "version": "1.0",
										 "supportedConnectionTypes": ["long-polling"]]])
			guard let handshake = reply.first(where: { $0["channel"] as? String == "/meta/handshake" }),
				  handshake["successful"] as? Bool == true, let id = handshake["clientId"] as? String else { throw Failure() }
			clientID = id
			serverSubscribed = false
			listed = []
			subscribed = []
		}
		guard let clientID else { throw Failure() }

		var messages: [[String: Any]] = [["channel": "/meta/connect", "clientId": clientID, "connectionType": "long-polling",
										  "advice": ["timeout": Int(Self.pollWait * 1000)]]]
		var asked: [Int: String] = [:] // subscribe ID -> "" (serverstatus) or a MAC
		func subscribe(_ key: String, response: String, request: [Any]) {
			let id = nextID
			nextID += 1
			asked[id] = key
			messages.append(["channel": "/slim/subscribe", "clientId": clientID, "id": id,
							 "data": ["response": "/\(clientID)/slim/\(response)", "request": request]])
		}
		if !serverSubscribed { subscribe("", response: "serverstatus", request: ["", Self.serverStatusRequest]) }
		for mac in players.intersection(listed).subtracting(subscribed).sorted() {
			subscribe(mac, response: "playerstatus/\(mac)", request: [mac, Self.statusRequest])
		}

		let reply = try await send(messages, timeout: Self.pollWait + Self.pollMargin)
		guard let connect = reply.first(where: { $0["channel"] as? String == "/meta/connect" }),
			  connect["successful"] as? Bool == true else {
			let advice = reply.first(where: { $0["channel"] as? String == "/meta/connect" })?["advice"] as? [String: Any]
			if advice?["reconnect"] as? String == "handshake" { self.clientID = nil }
			throw Failure()
		}

		var events: [Event] = []
		if !healthy {
			healthy = true
			events.append(.restored)
		}
		let prefix = "/\(clientID)/slim/"
		for message in reply {
			let channel = message["channel"] as? String ?? ""
			if channel == "/slim/subscribe", message["successful"] as? Bool == true,
			   let id = (message["id"] as? NSNumber)?.intValue ?? Int("\(message["id"] ?? "")"), let key = asked[id] {
				if key.isEmpty { serverSubscribed = true } else { subscribed.insert(key) }
				continue
			}
			guard channel.hasPrefix(prefix), let data = message["data"] as? [String: Any] else { continue }
			let topic = channel.dropFirst(prefix.count)
			if topic == "serverstatus" {
				let status = LMSServerStatus(data)
				listed = Set(status.players.keys)
				// a player LMS forgot loses its subscription there: subscribe again when it is back
				subscribed.formIntersection(listed)
				events.append(.serverStatus(status))
			} else if topic.hasPrefix("playerstatus/") {
				events.append(.status(String(topic.dropFirst("playerstatus/".count)).lowercased(), LMSPlayerStatus(data)))
			}
		}
		return events
	}

	private func send(_ messages: [[String: Any]], timeout: TimeInterval = pollWait + pollMargin) async throws -> [[String: Any]] {
		let body = try JSONSerialization.data(withJSONObject: messages)
		let data = try await transport.post(body, timeout: timeout)
		guard let reply = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure() }
		return reply
	}
}
