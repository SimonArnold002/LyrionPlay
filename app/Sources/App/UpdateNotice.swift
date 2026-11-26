import AppKit
import Observation
import PlayerCore

/// The update notice (ledger UPDATE NOTICE): asks GitHub for the latest release at launch, then once a
/// day on the wall clock (UpdateCheck.isDue). `available` is that release's version while it is newer
/// than this build.
@MainActor @Observable
final class UpdateNotice {
	static let shared = UpdateNotice()

	private(set) var notice = UpdateCheck.Notice()
	/// the menu's link
	var available: String? { notice.available }
	@ObservationIgnored private var checking = false
	@ObservationIgnored private var timer: Timer?
	@ObservationIgnored private var wakeObserver: NSObjectProtocol?
	@ObservationIgnored private let session: URLSession = {
		let config = URLSessionConfiguration.ephemeral // no cookies, nothing on disk
		// nor a reply kept in memory, which sent If-None-Match and If-Modified-Since with the next check
		// (/code-review 2026-11-26 (2), finding 4)
		config.urlCache = nil
		config.waitsForConnectivity = true // a check at login waits for the network
		config.timeoutIntervalForResource = 3600
		return URLSession(configuration: config)
	}()

	func start() {
		guard timer == nil else { return }
		checkIfDue()
		// every tick, so a day is counted on the wall clock, sleep included, and a failed check is tried
		// again within the hour
		timer = Timer.scheduledTimer(withTimeInterval: UpdateCheck.tick, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.checkIfDue() }
		}
		// and at wake: a Mac awake under an hour at a time seldom reaches a tick (finding 2)
		wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.checkIfDue() }
		}
	}

	private func checkIfDue() {
		let sent = Date()
		guard !checking, UpdateCheck.isDue(notice, now: sent) else { return }
		checking = true
		var request = URLRequest(url: UpdateCheck.latestAPI)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("LyrionPlay/\(AppVersion.version)", forHTTPHeaderField: "User-Agent")
		// fixed: URLSession would send the user's own language list (/code-review 2026-11-26, finding 3)
		request.setValue("en", forHTTPHeaderField: "Accept-Language")
		Task { [weak self, session] in
			let answer = try? await session.data(for: request)
			guard let self else { return }
			checking = false
			notice = UpdateCheck.after(notice, sent: sent, status: (answer?.1 as? HTTPURLResponse)?.statusCode,
									   reply: answer?.0, current: AppVersion.version)
		}
	}
}
