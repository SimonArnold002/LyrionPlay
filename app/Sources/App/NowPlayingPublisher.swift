// macOS Now Playing (themmm/LyrionPlay#1): one Player's Current track in Control Center, the media
// keys and apps such as boring.notch, and their commands sent to LMS. The rules are PlayerCore's
// (NowPlaying, RemoteCommand, LMSFeed); this file only runs the subscription, downloads the artwork
// and makes the MPNowPlayingInfoCenter / MPRemoteCommandCenter calls. The agent and the engine are
// not involved.
import AppKit
import MediaPlayer
import os
import PlayerCore

@MainActor
final class NowPlayingPublisher {
	private var state: NowPlaying?
	private var feed: LMSFeed?
	private var feedTask: Task<Void, Never>?
	/// what was last handed to macOS; nil when the slot is free
	private var published: NowPlayingInfo?
	private var artwork: (url: URL, image: MPMediaItemArtwork)?
	private var artworkLoading: URL?
	private var timer: Timer?
	/// what the remote command handlers act on, readable from whichever thread MediaPlayer calls them on
	private let target = OSAllocatedUnfairLock<(info: NowPlayingInfo, server: LMSServer)?>(initialState: nil)

	init() {
		registerCommands()
		setCommandsEnabled(false)
		// frees the slot when the 5 s grace of a lost subscription runs out
		timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.publish() }
		}
	}

	/// At each PlayerModel refresh: the server the agent last used (status.json) and the saved
	/// settings. A new server starts a new subscription; Off runs none.
	func update(server: LMSServer?, settings: PlayerCore.Settings) {
		let players = NowPlaying.players(in: settings) { PlayerIdentity.mac(at: Paths.mac($0)) }
		let choice = settings.nowPlaying
		let wanted = choice == .off ? nil : server
		if wanted.map(Self.address) != state.map({ Self.address($0.server) }) {
			stopFeed()
			if let wanted {
				state = NowPlaying(server: wanted, players: players, choice: choice)
				startFeed(on: wanted, players: players)
			}
		} else if var current = state, current.players != players || current.choice != choice {
			current.update(players: players, choice: choice)
			state = current
			let feed = self.feed, macs = players.compactMap(\.mac)
			Task { await feed?.setPlayers(macs) }
		}
		publish()
	}

	/// the name LMS's discovery gives can come and go; the server is its address
	private static func address(_ server: LMSServer) -> String { "\(server.host):\(server.webPort)" }

	private func startFeed(on server: LMSServer, players: [NowPlayingPlayer]) {
		guard let transport = HTTPCometd(server: server) else { return }
		let feed = LMSFeed(transport: transport, players: players.compactMap(\.mac))
		self.feed = feed
		feedTask = Task {
			await feed.run { [weak self] events in
				await self?.apply(events)
			}
		}
	}

	private func stopFeed() {
		feedTask?.cancel()
		feedTask = nil
		feed = nil
		state = nil
	}

	private func apply(_ events: [LMSFeed.Event]) {
		guard var current = state else { return }
		let now = Date()
		for event in events {
			switch event {
			case .restored: current.restored(at: now)
			case .lost: current.lost(at: now)
			case .serverStatus(let status): current.serverStatus(status, at: now)
			case .status(let mac, let status): current.status(status, of: mac, at: now)
			}
		}
		state = current
		publish()
	}

	private func publish(force: Bool = false) {
		let info = state?.shown(at: Date())
		guard force || info != published else { return }
		published = info
		let entry = info.flatMap { info in state.map { (info: info, server: $0.server) } }
		target.withLock { $0 = entry }
		let center = MPNowPlayingInfoCenter.default()
		guard let info else {
			// what the prototype found frees the slot for boring.notch and Control Center
			center.nowPlayingInfo = nil
			center.playbackState = .stopped
			setCommandsEnabled(false)
			return
		}
		var values: [String: Any] = [
			MPMediaItemPropertyTitle: info.title,
			MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
			MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0,
			MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
		]
		if let artist = info.artist { values[MPMediaItemPropertyArtist] = artist }
		if let album = info.album { values[MPMediaItemPropertyAlbumTitle] = album }
		if info.isLiveStream {
			values[MPNowPlayingInfoPropertyIsLiveStream] = true
		} else {
			if let duration = info.duration { values[MPMediaItemPropertyPlaybackDuration] = duration }
			if let elapsed = info.elapsed(at: Date()) { values[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
		}
		if let url = info.artwork {
			if let artwork, artwork.url == url {
				values[MPMediaItemPropertyArtwork] = artwork.image
			} else {
				loadArtwork(url)
			}
		}
		center.nowPlayingInfo = values
		center.playbackState = info.playing ? .playing : .paused
		setCommandsEnabled(true)
		MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = info.canSeek
	}

	/// the image LMS serves for the track; shown once it is here, if the track is still the same
	private func loadArtwork(_ url: URL) {
		guard artworkLoading != url else { return }
		artworkLoading = url
		Task { [weak self] in
			let data = try? await URLSession.shared.data(from: url).0
			guard let self else { return }
			if self.artworkLoading == url { self.artworkLoading = nil }
			guard let data, let image = NSImage(data: data) else { return }
			self.artwork = (url, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
			if self.published?.artwork == url { self.publish(force: true) }
		}
	}

	// MARK: commands from the notch, Control Center and the media keys

	private func registerCommands() {
		let center = MPRemoteCommandCenter.shared()
		// the notch sends togglePlayPause, never play or pause alone (prototype, 2026-11-21): all three
		center.togglePlayPauseCommand.addTarget { [target] _ in Self.send(.togglePlayPause, to: target) }
		center.playCommand.addTarget { [target] _ in Self.send(.play, to: target) }
		center.pauseCommand.addTarget { [target] _ in Self.send(.pause, to: target) }
		center.nextTrackCommand.addTarget { [target] _ in Self.send(.next, to: target) }
		center.previousTrackCommand.addTarget { [target] _ in Self.send(.previous, to: target) }
		center.changePlaybackPositionCommand.addTarget { [target] event in
			guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
			return Self.send(.seek(event.positionTime), to: target)
		}
	}

	private func setCommandsEnabled(_ on: Bool) {
		let center = MPRemoteCommandCenter.shared()
		for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand,
						center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand] {
			command.isEnabled = on
		}
	}

	/// the command for the Player in the slot, sent to LMS; refused when it has none (a seek on a
	/// stream: the notch sends one even with seeking disabled)
	nonisolated private static func send(_ command: RemoteCommand,
										 to target: OSAllocatedUnfairLock<(info: NowPlayingInfo, server: LMSServer)?>)
		-> MPRemoteCommandHandlerStatus {
		guard let (info, server) = target.withLock({ $0 }) else { return .noActionableNowPlayingItem }
		guard let lms = command.lms(for: info) else { return .commandFailed }
		Task { _ = await LMSClient(server: server).call(player: info.mac, lms) }
		return .success
	}
}
