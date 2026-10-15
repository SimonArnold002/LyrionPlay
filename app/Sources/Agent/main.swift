// The LyrionPlay agent. launchd starts it at login (PlayerCore.LaunchAgent). It runs one squeezelite
// engine per player that is on (ONE PLAYER PER DAC): *Follow the macOS output*, and each device whose
// own player is switched on in Settings. Each engine's arguments are built from the settings and the
// device's probed capabilities. It restarts an engine that exits unexpectedly, follows device and
// settings changes, and writes status.json for the menu bar app. It also keeps the menu app open
// while it runs. It only ever signals engine PIDs it started.
import Foundation
import os
import PlayerCore

final class Log {
	private let formatter = ISO8601DateFormatter()

	func callAsFunction(_ text: String) {
		let line = "\(formatter.string(from: Date())) [\(getpid())] \(text)\n"
		guard let data = line.data(using: .utf8) else { return }
		if let handle = try? FileHandle(forWritingTo: Paths.agentLog) {
			handle.seekToEndOfFile()
			handle.write(data)
			try? handle.close()
		} else {
			try? data.write(to: Paths.agentLog)
		}
	}
}

let log = Log()

/// a report from a player's engine, with where to send it
struct VolumeChange: Sendable {
	var report: VolumeReport
	var server: LMSServer
	var mac: String
	/// the player's name, for the log
	var player: String
}

func modificationDate(_ url: URL) -> Date? {
	(try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

/// keeps one older copy. Called only when the agent or an engine starts, and both can run for a
/// whole login session, so a log can grow past `bytes` until the next start (with "Debug" logging,
/// an engine's log grows fastest).
func rotate(_ url: URL, above bytes: Int) {
	guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
		  size > bytes else { return }
	let old = url.appendingPathExtension("1")
	try? FileManager.default.removeItem(at: old)
	try? FileManager.default.moveItem(at: url, to: old)
}

/// One player: its LMS identity and the engine that plays it.
final class PlayerSlot {
	let key: String
	let mac: String
	/// the player's name, for the log and the menu
	var name: String
	var engine: Process?
	var args: [String]?
	/// a rename: the name file is read at the engine's start, so the next reconcile restarts it
	var restartWanted = false
	/// the device the running engine plays to
	var device: DeviceCaps?
	/// what the running engine last said it plays (PCM, or DoP at a rate); nil until it says, and
	/// again once it lets go of the device (`lyrionplay:format idle`, FormatLine)
	var format: FormatReport?
	var expectedExit: Int32?
	var restartWork: DispatchWorkItem?
	var backoff: TimeInterval = 1
	var startedAt = Date.distantPast
	/// what went wrong with the engine (it could not start, it stopped)
	var problem: String?
	/// what keeps it from playing as set: no device, or Fixed with no level to hold
	var setupProblem: String?
	/// LMS's "Output level fixed at 100%" for this player, following its setting; locked: `checked`
	/// runs on the main queue, `recordRefusal` on the send's own task (syncFixedVolume)
	let fixedVolume = OSAllocatedUnfairLock(initialState: FixedVolumeSync())
	/// Mac volume -> LMS: one push at a time, at most one per 150 ms while a key is held, the latest
	/// level winning (VolumeSync.swift). One per player, so one player's push never drops another's.
	let volumeSender = LatestValueSender<VolumeChange>(interval: 0.15) { change in
		let client = LMSClient(server: change.server)
		guard let command = await VolumePush.command(for: change.report,
													 volumeFixed: { await client.volumeFixed(player: change.mac) },
													 lmsVolume: { await client.volume(player: change.mac) }) else {
			DispatchQueue.main.async { log("\(change.player): the Mac's volume changed, but LMS's volume is fixed for this player; not sent") }
			return
		}
		DispatchQueue.main.async {
			let report = change.report
			log("\(change.player): the Mac's volume changed (\(String(format: "%.2f", report.dB)) dB\(report.muted ? ", muted" : "")): LMS \(command.joined(separator: " "))")
		}
		_ = await client.call(player: change.mac, command)
	}

	init(key: String, mac: String, name: String) {
		self.key = key
		self.mac = mac
		self.name = name
	}
}

final class Supervisor {
	/// the defaults until `run` reads settings.json (readSettings)
	private var settings = Settings()
	private var settingsDate: Date?
	private var devices: [DeviceCaps] = []
	/// one per player that is on
	private var slots: [String: PlayerSlot] = [:]
	/// *Follow the macOS output*, held on its engine's device while it has exclusive access
	private var follow = OutputFollow()
	private var watcher: AudioDeviceWatcher?
	private var timer: DispatchSourceTimer?
	private var signalSources: [DispatchSourceSignal] = []
	private var reconcilePending = false
	/// the server for the status and volume pushes, and what it said of each player; a check begun
	/// before a server change is dropped
	private var lms: ServerChoice
	private var lastLMSCheck = Date.distantPast
	private var lmsCheckRunning = false
	private var checkLog = LMSCheckLog()
	/// a problem of the whole player (the engine missing from the app)
	private var problem: String?
	private let engineURL = Paths.executable("squeezelite")
	private var shuttingDown = false
	private var nextMenuOpen = Date.distantPast
	private var menuOpenedAt: Date?
	private var menuBackoff: TimeInterval = 5
	private var lastNoServerLog = Date.distantPast

	init() {
		lms = ServerChoice(setting: settings.server)
	}

	func run() -> Never {
		do {
			try Paths.createDirectories()
		} catch {
			exit(1)
		}
		rotate(Paths.agentLog, above: 2_000_000)
		log("agent started: LyrionPlay \(AppVersion.description); engine \(engineURL.path)")
		guard FileManager.default.isExecutableFile(atPath: engineURL.path) else {
			log("the engine is missing")
			problem = "The player engine is missing from the app"
			writeStatus()
			exit(1) // KeepAlive restarts us; a reinstall fixes it
		}
		// settings from before players (0.3.x) are not carried over (Simon, 2026-10-12: "no migration")
		do {
			if let aside = try Settings.setAsideOlder() {
				log("settings from an older version moved to \(aside.lastPathComponent); starting with the defaults")
			}
		} catch {
			log("cannot set the older settings aside: \(error)")
		}
		readSettings()
		lms = ServerChoice(setting: settings.server)
		if !FileManager.default.fileExists(atPath: Paths.settings.path) {
			try? settings.save()
		}
		settingsDate = modificationDate(Paths.settings)

		for sig in [SIGTERM, SIGINT] {
			signal(sig, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
			source.setEventHandler { [weak self] in self?.shutdown(sig) }
			source.resume()
			signalSources.append(source)
		}
		watcher = AudioDeviceWatcher { [weak self] in self?.scheduleReconcile("audio devices changed") }
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + 2, repeating: 2)
		timer.setEventHandler { [weak self] in self?.tick() }
		timer.resume()
		self.timer = timer

		// a new agent means a new session, or a restart after a crash: an old marker is stale
		try? FileManager.default.removeItem(at: MenuPresence.sessionEnding)
		stopOrphanedEngines()
		reconcile("start")
		dispatchMain()
	}

	/// An agent that crashed leaves its engines running: Process starts children in their own
	/// process group, so launchd does not take them down with the job. Measured 2026-10-09: after
	/// `kill -9` of the agent, the old engine (parent now PID 1) and the new agent's engine both ran
	/// with the same player identity. Stop each one named in a player's engine.pid (and in 0.3.x's
	/// one), and only if that PID is alive AND is this engine executable.
	private func stopOrphanedEngines() {
		let folders = (try? FileManager.default.contentsOfDirectory(at: Paths.players, includingPropertiesForKeys: nil)) ?? []
		for pidFile in folders.map({ $0.appendingPathComponent("engine.pid") }) + [Paths.oldEnginePID] {
			defer { try? FileManager.default.removeItem(at: pidFile) }
			guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
				  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
				  kill(pid, 0) == 0 else { continue }
			var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
			guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
				  String(cString: buffer) == engineURL.path else { continue }
			log("stopping engine \(pid), left running by a previous agent")
			kill(pid, SIGTERM)
			let deadline = Date().addingTimeInterval(3)
			while kill(pid, 0) == 0 && Date() < deadline { usleep(50_000) }
			if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
		}
	}

	/// settings.json, at the start and at each change: no file gives the defaults; a file that does not
	/// decode is said and left as it is, and the players keep the settings they have (Settings.Stored)
	private func readSettings() {
		switch Settings.read() {
		case .current(let read): settings = read
		case .older, .missing: settings = Settings()
		case .unreadable(let why): log("settings.json cannot be read, left as it is: \(why)")
		}
	}

	/// device notifications arrive in bursts: act once, a second after the first
	private func scheduleReconcile(_ reason: String) {
		guard !reconcilePending else { return }
		reconcilePending = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
			self?.reconcilePending = false
			self?.reconcile(reason)
		}
	}

	/// the players that are on: *Follow the macOS output* first, then the others in the list's order
	private var playersOn: [String] {
		PlayerList.rows(settings: settings, devices: devices).map(\.key).filter { settings.isOn($0) }
	}

	/// probe the devices, then (re)start only the engines whose arguments changed, stopping every one
	/// that changed or ended before starting any, so two engines never hold one device
	private func reconcile(_ reason: String) {
		devices = DeviceCaps.probe(engine: engineURL)
		let on = playersOn
		let wasDeferred = follow.deferred
		// nil while *Follow the macOS output* is off, which also ends a wait (OutputFollow)
		let followDevice = follow.resolve(settings, in: devices, holding: heldDevice(PlayerKey.follow))
		// Taking exclusive access moves the macOS default output elsewhere; that is not the user
		// choosing another output. Follow it once the engine lets go (tick).
		if follow.deferred && !wasDeferred, let device = followDevice {
			log("\(reason): the macOS output is elsewhere while \(playerName(PlayerKey.follow)) holds \(device.name) exclusively; staying on it until it lets go")
		}
		for key in on where slots[key] == nil {
			guard let slot = makeSlot(key) else { continue }
			slots[key] = slot
		}
		let plan = EnginePlan.make(settings: settings, devices: devices, followDevice: followDevice) { key, device in
			guard let slot = slots[key] else { return [] }
			return EngineArguments.build(settings: settings, key: key, device: device, mac: slot.mac,
										 nameFile: Paths.playerName(key).path, logFile: Paths.engineLog(key).path)
		}.filter { slots[$0.key] != nil }
		let running = slots.compactMapValues { slot -> [String]? in
			guard slot.engine != nil else { return nil }
			return slot.restartWanted ? [] : slot.args ?? []
		}
		let changes = EnginePlan.changes(running: running, wanted: plan)
		var stopping: [PlayerSlot] = []
		for key in changes.stop {
			guard let slot = slots[key] else { continue }
			if plan[key] == nil {
				log("\(reason): stopping the engine of \(slot.name)\(on.contains(key) ? ": its device is not present" : ": switched off")")
			}
			stopping.append(slot)
		}
		// players switched off: their engines are stopped with the others; nothing more is known of them.
		// One with an engine is in changes.stop too, so it is passed twice: stopEngines skips the second
		// (its engine is nil by then). One without (waiting to restart) is only here, and stopEngines
		// cancels its restart.
		for key in slots.keys where !on.contains(key) {
			if let slot = slots[key] { stopping.append(slot) }
			slots[key] = nil
		}
		stopEngines(stopping)
		for key in changes.start {
			guard let slot = slots[key], let spec = plan[key] else { continue }
			log("\(reason): \(running[key] == nil ? "starting" : "restarting") the engine of \(slot.name) on \(spec.device.name)")
			startEngine(slot, spec)
		}
		for (key, slot) in slots {
			guard let spec = plan[key] else {
				slot.setupProblem = key == PlayerKey.follow ? "No output device" : "Not connected"
				continue
			}
			// only a hand-edited file gets here: the Settings window saves no Fixed without a level
			let options = settings.player(key, device: spec.device)
			slot.setupProblem = options.volume == .fixed && spec.device.volume != nil && options.heldVolume == nil
				? "Fixed has no level to hold: choose Fixed again in its settings" : nil
		}
		writeStatus()
	}

	/// a player's name in LMS, for the log and the menu (LMS OWNS THE PLAYER NAME): settings.json's
	/// until LMS has named it
	private func playerName(_ key: String) -> String {
		PlayerIdentity.name(at: Paths.playerName(key)) ?? settings.player(key, device: devices.first { $0.uid == key }).name
	}

	/// a player's identity in LMS, made once and kept (PlayerIdentity), and its name (playerName)
	private func makeSlot(_ key: String) -> PlayerSlot? {
		let name = playerName(key)
		do {
			if key == PlayerKey.follow,
			   let mac = try PlayerIdentity.adoptOldPlayer(mac: Paths.oldMAC, name: Paths.oldPlayerName,
															macAt: Paths.mac(key), nameAt: Paths.playerName(key)) {
				log("\(name) carries on as the earlier version's player \(mac)")
			}
			let mac = try PlayerIdentity.loadOrCreateMAC(at: Paths.mac(key))
			return PlayerSlot(key: key, mac: mac, name: name)
		} catch {
			log("cannot create the identity of \(name): \(error)")
			return nil
		}
	}

	/// a player's engine's device, while that engine holds it exclusively
	private func heldDevice(_ key: String) -> String? {
		guard let slot = slots[key], let device = slot.device, let pid = slot.engine?.processIdentifier,
			  let id = CoreAudioQuery.device(uid: device.uid), CoreAudioQuery.hogOwner(id) == pid else { return nil }
		return device.uid
	}

	private func startEngine(_ slot: PlayerSlot, _ spec: EngineSpec) {
		slot.restartWork?.cancel()
		slot.restartWork = nil
		let logURL = Paths.engineLog(slot.key)
		rotate(logURL, above: 5_000_000)
		if !FileManager.default.fileExists(atPath: logURL.path) {
			FileManager.default.createFile(atPath: logURL.path, contents: nil)
		}
		let process = Process()
		process.executableURL = engineURL
		process.arguments = spec.args
		// the engine reports volume changes made on the Mac here (output_coreaudio.c, volume_listener),
		// and what it plays (ca_report_format)
		let reports = Pipe()
		process.standardOutput = reports
		var partial = ""
		reports.fileHandleForReading.readabilityHandler = { [weak self, weak slot, weak process] handle in
			let data = handle.availableData
			if data.isEmpty {
				handle.readabilityHandler = nil // the engine exited
				return
			}
			partial += String(decoding: data, as: UTF8.self)
			while let newline = partial.firstIndex(of: "\n") {
				let line = String(partial[..<newline])
				partial.removeSubrange(...newline)
				// a line from an engine already replaced says nothing of what plays now: its volume
				// was another device's, or the same device's before a setting changed
				// (/code-review 2026-10-12 (2), finding 5)
				if let report = VolumeReport(line: line) {
					DispatchQueue.main.async {
						guard let self, let slot, let process, slot.engine === process else { return }
						self.deviceVolumeChanged(slot, report)
					}
				} else if let format = FormatLine(line: line) {
					DispatchQueue.main.async {
						guard let self, let slot, let process, slot.engine === process else { return }
						slot.format = format.report // nil once the engine lets go of the device
						self.writeStatus()
					}
				}
			}
		}
		// anything printed before the engine opens its own log (a bad option, say) lands there too
		if let handle = try? FileHandle(forWritingTo: logURL) {
			handle.seekToEndOfFile()
			process.standardError = handle
		}
		process.terminationHandler = { [weak self] finished in
			let pid = finished.processIdentifier, status = finished.terminationStatus
			DispatchQueue.main.async { self?.engineExited(pid: pid, status: status) }
		}
		do {
			try process.run()
		} catch {
			log("cannot start the engine of \(slot.name): \(error)")
			slot.problem = "The player engine could not start"
			scheduleRestart(slot)
			return
		}
		slot.engine = process
		slot.args = spec.args
		slot.restartWanted = false
		slot.device = spec.device
		slot.startedAt = Date()
		slot.problem = nil
		try? String(process.processIdentifier).write(to: Paths.enginePID(slot.key), atomically: true, encoding: .utf8)
		log("engine \(process.processIdentifier) of \(slot.name) started: \(spec.args.joined(separator: " "))")
	}

	/// SIGTERM to every engine first, then one wait of up to 3 s for them all. One at a time, a server
	/// change (which restarts every engine) or a shutdown held the main queue ~0.2 s per engine, and up
	/// to 3 s for each that hung (/code-review 2026-10-14, finding 6).
	private func stopEngines(_ stopping: [PlayerSlot]) {
		var stopped: [(name: String, process: Process)] = []
		for slot in stopping {
			slot.restartWork?.cancel()
			slot.restartWork = nil
			guard let process = slot.engine else { continue }
			slot.engine = nil
			slot.args = nil
			slot.device = nil
			slot.format = nil
			try? FileManager.default.removeItem(at: Paths.enginePID(slot.key))
			slot.expectedExit = process.processIdentifier
			process.terminate()
			stopped.append((slot.name, process))
		}
		let deadline = Date().addingTimeInterval(3)
		while stopped.contains(where: { $0.process.isRunning }) && Date() < deadline { usleep(50_000) }
		for (name, process) in stopped where process.isRunning {
			log("engine \(process.processIdentifier) of \(name) did not stop; killing it")
			kill(process.processIdentifier, SIGKILL)
		}
	}

	/// The Mac's volume keys or menu bar slider moved a player's device: move that player's LMS slider
	/// to match, so the volume works both ways. The engine reports only changes it did not make
	/// itself, and LMS's reply puts the same level back on the device, so nothing echoes.
	private func deviceVolumeChanged(_ slot: PlayerSlot, _ report: VolumeReport) {
		guard let server = lms.server else {
			// a held key reports many times a second: say it once
			if Date().timeIntervalSince(lastNoServerLog) > 5 {
				lastNoServerLog = Date()
				log("\(slot.name): the Mac's volume changed, but no server is known yet; not sent")
			}
			return
		}
		slot.volumeSender.submit(VolumeChange(report: report, server: server, mac: slot.mac, player: slot.name))
	}

	private func engineExited(pid: Int32, status: Int32) {
		for slot in slots.values {
			if pid == slot.expectedExit {
				slot.expectedExit = nil
				return
			}
			guard slot.engine?.processIdentifier == pid else { continue }
			slot.engine = nil
			slot.args = nil
			slot.device = nil
			slot.format = nil
			try? FileManager.default.removeItem(at: Paths.enginePID(slot.key))
			let ran = Date().timeIntervalSince(slot.startedAt)
			if ran > 60 { slot.backoff = 1 }
			log("engine \(pid) of \(slot.name) exited unexpectedly (status \(status)) after \(Int(ran)) s; restarting in \(Int(slot.backoff)) s")
			slot.problem = "The player engine stopped; restarting"
			scheduleRestart(slot)
			return
		}
	}

	private func scheduleRestart(_ slot: PlayerSlot) {
		let work = DispatchWorkItem { [weak self] in self?.reconcile("restart") }
		slot.restartWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + slot.backoff, execute: work)
		slot.backoff = min(slot.backoff * 2, 30)
	}

	private func tick() {
		let date = modificationDate(Paths.settings)
		if date != settingsDate {
			settingsDate = date
			readSettings()
			if lms.update(setting: settings.server) { // check the new one now, and say what it finds
				lastLMSCheck = .distantPast
				checkLog.settingChanged()
			}
			reconcile("settings changed")
			// a player's "LMS volume" may have changed: check LMS at once (FixedVolumeSync). A change to
			// or from the device's own volume or Fixed restarts its engine, and the check in this tick
			// does not sync it (only a connected player is synced): it followed at the next check, 6 s
			// after the change, both ways, live 2026-10-12 (/code-review 2026-10-12, finding 6)
			lastLMSCheck = .distantPast
		}
		// macOS puts its default output back when the engine lets go of a device it held, which
		// reconciles by itself; this catches a different output chosen meanwhile
		if follow.deferred, follow.shouldReconcile(holding: heldDevice(PlayerKey.follow)) {
			scheduleReconcile("the engine let go of its device")
		}
		if Date().timeIntervalSince(lastLMSCheck) >= 5 {
			lastLMSCheck = Date()
			refreshLMS()
		}
		ensureMenu()
		writeStatus()
	}

	/// While the player runs, its menu is there (Simon, 2026-10-09: the two are tied). This opens
	/// the menu at login and reopens it if it goes for any reason but the session ending. Quit in
	/// the menu stops this agent before the menu exits, so a chosen quit never comes back. A menu
	/// that keeps dying is reopened less and less often, up to every 5 minutes.
	private func ensureMenu() {
		guard !shuttingDown, Paths.appBundle.pathExtension == "app" else { return }
		if MenuPresence.isRunning() {
			if let opened = menuOpenedAt, Date().timeIntervalSince(opened) > 60 {
				menuOpenedAt = nil
				menuBackoff = 5
			}
			return
		}
		if MenuPresence.holdsOff() { return } // the session is ending, or install.sh is replacing the menu
		guard Date() >= nextMenuOpen else { return }
		log("the menu app is not running; opening it")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
		process.arguments = ["-g", Paths.appBundle.path]
		do {
			try process.run()
		} catch {
			log("cannot open the menu app: \(error)")
		}
		menuOpenedAt = Date()
		nextMenuOpen = Date().addingTimeInterval(menuBackoff)
		menuBackoff = min(menuBackoff * 2, 300)
	}

	/// finds the server (or uses the configured one) and asks it about every player that is on
	private func refreshLMS() {
		guard !lmsCheckRunning else { return }
		lmsCheckRunning = true
		let configured = lms.setting, macs = slots.values.map(\.mac), known = lms.server
		Task.detached { [weak self] in
			// timed here, on the check's own task, with a clock that stops while the Mac sleeps: the
			// main queue may be busy (a device probe, an engine stop) when the result reaches it, and
			// Date counted a sleep as LMS's time (/code-review 2026-10-11 (3), finding 3)
			let clock = SuspendingClock(), began = clock.now
			var found = known
			if found == nil {
				let host = configured.isEmpty ? nil : configured.split(separator: ":").first.map(String.init)
				found = LMSDiscovery.find(host: host) ?? host.map { LMSServer(host: $0, webPort: 9000, name: nil) }
			}
			var states: [String: LMSClient.PlayerState]?
			var answer: TimeInterval?
			if let server = found {
				let asked = clock.now
				states = await LMSClient(server: server).playerStates(macs: macs)
				answer = asked.duration(to: clock.now) / .seconds(1)
			}
			let checked = found, took = began.duration(to: clock.now) / .seconds(1)
			DispatchQueue.main.async {
				guard let self else { return }
				self.lmsCheckRunning = false
				// unreachable: look again next time. Begun before the server setting changed: dropped,
				// and the new one is checked at the next tick, not 5 s after this check began
				let kept = self.lms.checked(setting: configured, found: states == nil ? nil : checked, states: states ?? [:])
				if !kept { self.lastLMSCheck = .distantPast }
				// how a stalled server is seen: slow checks, dropped ones and the server used (LMSCheckLog)
				let end: LMSCheckLog.End = kept ? .kept(answered: states != nil, answer: answer)
					: .dropped(began: configured, now: self.lms.setting, took: took)
				for line in self.checkLog.ended(end, found: checked) { log(line) }
				guard kept, let states, let server = checked else { return }
				for slot in self.slots.values {
					if let state = states[slot.mac], state.connected { self.syncFixedVolume(slot, state, server: server) }
				}
			}
		}
	}

	/// LMS's "Output level fixed at 100%" for a player follows its "LMS volume" setting
	/// (FixedVolumeSync). `status` already carries the pref, so this costs requests only when LMS
	/// differs: the send, a read of what LMS kept, and the saved volume before and after (put back
	/// when LMS's hook changed it, `volumeRestore`).
	private func syncFixedVolume(_ slot: PlayerSlot, _ state: LMSClient.PlayerState, server: LMSServer) {
		guard let device = slot.device else { return }
		let mode = settings.player(slot.key, device: device).volume, uid = device.uid, name = slot.name
		guard let command = slot.fixedVolume.withLock({ $0.checked(device: uid, mode: mode, lms: state.digitalVolumeControl) }) else { return }
		log("LMS volume for \(name): \(mode == .fixed ? "setting it to fixed at 100%" : "turning volume control back on"), as this player's setting says")
		let mac = slot.mac, sync = slot.fixedVolume
		Task.detached {
			let client = LMSClient(server: server)
			let volumeBefore = await client.volume(player: mac)
			_ = await client.call(player: mac, command)
			let after = await client.digitalVolumeControl(player: mac)
			// LMS saves a faded (temporary) volume as the real one when this pref changes
			let volumeAfter = await client.volume(player: mac)
			// a restore needs both reads (aFadedVolumeLMSSavedIsPutBack), so volumeAfter is there with one
			if let restore = FixedVolumeSync.volumeRestore(before: volumeBefore, after: volumeAfter), let volumeAfter {
				_ = await client.call(player: mac, restore)
				DispatchQueue.main.async {
					log("LMS volume for \(name): LMS saved its faded volume (\(volumeAfter)) as the player's volume when the setting changed; put back: \(restore.joined(separator: " "))")
				}
			}
			guard sync.withLock({ $0.recordRefusal(device: uid, mode: mode, lmsAfter: after) }) else { return }
			DispatchQueue.main.async {
				log("LMS volume for \(name): LMS did not take digitalVolumeControl \(FixedVolumeSync.value(for: mode)); not sent again until the device or its volume setting changes")
			}
		}
	}

	private func writeStatus() {
		var status = AgentStatus(agentPID: getpid())
		status.devices = devices
		status.serverName = lms.server?.name ?? lms.server?.host
		status.serverHost = lms.server?.host
		status.serverWebPort = lms.server?.webPort
		status.problem = problem
		for key in playersOn {
			guard let slot = slots[key] else { continue }
			// LMS's name (the name file): a rename made in LMS shows in the menu within 2 s
			if let name = PlayerIdentity.name(at: Paths.playerName(key)) { slot.name = name }
			var player = PlayerStatus(key: key, name: slot.name, mac: slot.mac)
			player.engineRunning = slot.engine?.isRunning ?? false
			player.enginePID = slot.engine?.processIdentifier
			// the device actually played to, which for *Follow the macOS output* can differ from the
			// macOS output (follow.deferred)
			if let device = slot.device {
				player.deviceUID = device.uid
				player.deviceName = device.name
				if let id = CoreAudioQuery.device(uid: device.uid) {
					player.currentRate = CoreAudioQuery.nominalRate(id)
					player.currentFormat = CoreAudioQuery.physicalFormat(id)
					player.dsdRate = slot.format?.dsdRate(deviceRate: player.currentRate)
					if let owner = CoreAudioQuery.hogOwner(id), let pid = player.enginePID {
						player.exclusive = owner == pid
					}
				}
			}
			let state = lms.playerStates[slot.mac]
			player.connected = state?.connected ?? false
			player.mode = state?.mode
			player.nowPlaying = state?.nowPlaying
			player.problem = slot.problem ?? slot.setupProblem
			status.players.append(player)
		}
		try? status.save()
	}

	private func shutdown(_ sig: Int32) {
		shuttingDown = true
		log("signal \(sig): stopping")
		stopEngines(Array(slots.values))
		problem = nil
		lms.forgetPlayers()
		writeStatus()
		exit(0) // a clean exit: launchd's KeepAlive{SuccessfulExit=false} leaves us stopped
	}
}

// held for the life of the process: run() never returns, and its callbacks capture it weakly
let supervisor = Supervisor()
supervisor.run()
