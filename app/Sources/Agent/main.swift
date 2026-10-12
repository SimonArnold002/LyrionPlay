// The LyrionPlay agent. launchd starts it at login (PlayerCore.LaunchAgent). It runs the
// squeezelite engine with arguments built from the settings and the device's probed capabilities,
// restarts it if it exits unexpectedly, follows device and settings changes, and writes
// status.json for the menu bar app. It also keeps the menu app open while it runs. It only ever
// signals the engine PID it started.
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

/// a report from the engine, with where to send it
struct VolumeChange: Sendable {
	var report: VolumeReport
	var server: LMSServer
	var mac: String
}

func modificationDate(_ url: URL) -> Date? {
	(try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

/// keeps one older copy. Called only when the agent or the engine starts, and both can run for a
/// whole login session, so a log can grow past `bytes` until the next start (with "Debug" logging,
/// engine.log grows fastest).
func rotate(_ url: URL, above bytes: Int) {
	guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
		  size > bytes else { return }
	let old = url.appendingPathExtension("1")
	try? FileManager.default.removeItem(at: old)
	try? FileManager.default.moveItem(at: url, to: old)
}

final class Supervisor {
	private var settings: Settings
	private var settingsDate: Date?
	private var devices: [DeviceCaps] = []
	private var engine: Process?
	private var engineArgs: [String]?
	/// the device the running engine plays to
	private var engineDevice: DeviceCaps?
	/// what the running engine last said it plays (PCM, or DoP at a rate); nil until it says, and
	/// again once it lets go of the device (`lyrionplay:format idle`, FormatLine)
	private var engineFormat: FormatReport?
	/// following the macOS output, but held on the engine's device while it has exclusive access
	private var follow = OutputFollow()
	private var expectedExit: Int32?
	private var restartWork: DispatchWorkItem?
	private var backoff: TimeInterval = 1
	private var startedAt = Date.distantPast
	private var watcher: AudioDeviceWatcher?
	private var timer: DispatchSourceTimer?
	private var signalSources: [DispatchSourceSignal] = []
	private var reconcilePending = false
	private var mac = ""
	/// the server for the status and volume pushes, and what it said of the player; a check begun
	/// before a server change is dropped
	private var lms: ServerChoice
	private var lastLMSCheck = Date.distantPast
	private var lmsCheckRunning = false
	private var checkLog = LMSCheckLog()
	private var problem: String?
	private let engineURL = Paths.executable("squeezelite")
	private var shuttingDown = false
	private var nextMenuOpen = Date.distantPast
	private var menuOpenedAt: Date?
	private var menuBackoff: TimeInterval = 5
	private var lastNoServerLog = Date.distantPast
	/// LMS's "Output level fixed at 100%" for this player, following the engine device's setting;
	/// locked: `checked` runs on the main queue, `recordRefusal` on the send's own task (syncFixedVolume)
	private let fixedVolume = OSAllocatedUnfairLock(initialState: FixedVolumeSync())
	/// Mac volume -> LMS: one push at a time, at most one per 150 ms while a key is held, the
	/// latest level winning (VolumeSync.swift)
	private let volumeSender = LatestValueSender<VolumeChange>(interval: 0.15) { change in
		let client = LMSClient(server: change.server)
		guard let command = await VolumePush.command(for: change.report,
													 volumeFixed: { await client.volumeFixed(player: change.mac) },
													 lmsVolume: { await client.volume(player: change.mac) }) else {
			DispatchQueue.main.async { log("the Mac's volume changed, but LMS's volume is fixed for this player; not sent") }
			return
		}
		DispatchQueue.main.async {
			let report = change.report
			log("the Mac's volume changed (\(String(format: "%.2f", report.dB)) dB\(report.muted ? ", muted" : "")): LMS \(command.joined(separator: " "))")
		}
		_ = await client.call(player: change.mac, command)
	}

	init() {
		let settings = Settings.load()
		self.settings = settings
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
		if !FileManager.default.fileExists(atPath: Paths.settings.path) {
			try? settings.save()
		}
		settingsDate = modificationDate(Paths.settings)
		do {
			mac = try PlayerIdentity.loadOrCreateMAC()
			try PlayerIdentity.ensureNameFile(name: settings.playerName)
		} catch {
			log("cannot create the player identity: \(error)")
			exit(1)
		}

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
		stopOrphanedEngine()
		reconcile("start")
		dispatchMain()
	}

	/// An agent that crashed leaves its engine running: Process starts children in their own
	/// process group, so launchd does not take them down with the job. Measured 2026-10-09: after
	/// `kill -9` of the agent, the old engine (parent now PID 1) and the new agent's engine both ran
	/// with the same player identity. Stop the one named in engine.pid, and only if that PID is
	/// alive AND is this engine executable.
	private func stopOrphanedEngine() {
		defer { try? FileManager.default.removeItem(at: Paths.enginePID) }
		guard let text = try? String(contentsOf: Paths.enginePID, encoding: .utf8),
			  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
			  kill(pid, 0) == 0 else { return }
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
		guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
			  String(cString: buffer) == engineURL.path else { return }
		log("stopping engine \(pid), left running by a previous agent")
		kill(pid, SIGTERM)
		let deadline = Date().addingTimeInterval(3)
		while kill(pid, 0) == 0 && Date() < deadline { usleep(50_000) }
		if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
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

	/// probe the devices, build the arguments, and (re)start the engine only if they changed
	private func reconcile(_ reason: String) {
		devices = DeviceCaps.probe(engine: engineURL)
		let wasDeferred = follow.deferred
		guard let device = follow.resolve(settings, in: devices, holding: heldDevice()) else {
			if engine != nil { log("\(reason): output device \(settings.outputDevice) is not present; stopping the engine") }
			stopEngine()
			problem = settings.outputDevice == Settings.followSystem
				? "No output device" : "The chosen output device is not connected"
			writeStatus()
			return
		}
		// Taking exclusive access moves the macOS default output elsewhere; that is not the user
		// choosing another output. Follow it once the engine lets go (tick).
		if follow.deferred && !wasDeferred {
			log("\(reason): the macOS output is elsewhere while the engine holds \(device.name) exclusively; staying on it until it lets go")
		}
		let args = EngineArguments.build(settings: settings, device: device, mac: mac,
										 nameFile: Paths.playerName.path, logFile: Paths.engineLog.path)
		if args == engineArgs, engine != nil { return }
		log("\(reason): \(engine == nil ? "starting" : "restarting") the engine for \(device.name)")
		stopEngine()
		startEngine(args, device: device)
		writeStatus()
	}

	/// the engine's device, while the engine holds it exclusively
	private func heldDevice() -> String? {
		guard let device = engineDevice, let pid = engine?.processIdentifier,
			  let id = CoreAudioQuery.device(uid: device.uid), CoreAudioQuery.hogOwner(id) == pid else { return nil }
		return device.uid
	}

	private func startEngine(_ args: [String], device: DeviceCaps) {
		restartWork?.cancel()
		restartWork = nil
		rotate(Paths.engineLog, above: 5_000_000)
		if !FileManager.default.fileExists(atPath: Paths.engineLog.path) {
			FileManager.default.createFile(atPath: Paths.engineLog.path, contents: nil)
		}
		let process = Process()
		process.executableURL = engineURL
		process.arguments = args
		// the engine reports volume changes made on the Mac here (output_coreaudio.c, volume_listener),
		// and what it plays (ca_report_format)
		let reports = Pipe()
		process.standardOutput = reports
		var partial = ""
		reports.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
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
						guard let self, let process, self.engine === process else { return }
						self.deviceVolumeChanged(report)
					}
				} else if let format = FormatLine(line: line) {
					DispatchQueue.main.async {
						guard let self, let process, self.engine === process else { return }
						self.engineFormat = format.report // nil once the engine lets go of the device
						self.writeStatus()
					}
				}
			}
		}
		// anything printed before the engine opens its own log (a bad option, say) lands there too
		if let handle = try? FileHandle(forWritingTo: Paths.engineLog) {
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
			log("cannot start the engine: \(error)")
			problem = "The player engine could not start"
			scheduleRestart()
			return
		}
		engine = process
		engineArgs = args
		engineDevice = device
		startedAt = Date()
		problem = nil
		try? String(process.processIdentifier).write(to: Paths.enginePID, atomically: true, encoding: .utf8)
		log("engine \(process.processIdentifier) started: \(args.joined(separator: " "))")
	}

	private func stopEngine() {
		restartWork?.cancel()
		restartWork = nil
		guard let process = engine else { return }
		engine = nil
		engineArgs = nil
		engineDevice = nil
		engineFormat = nil
		try? FileManager.default.removeItem(at: Paths.enginePID)
		expectedExit = process.processIdentifier
		process.terminate()
		let deadline = Date().addingTimeInterval(3)
		while process.isRunning && Date() < deadline { usleep(50_000) }
		if process.isRunning {
			log("engine \(process.processIdentifier) did not stop; killing it")
			kill(process.processIdentifier, SIGKILL)
		}
	}

	/// The Mac's volume keys or menu bar slider moved the device: move LMS's slider to match, so the
	/// volume works both ways. The engine reports only changes it did not make itself, and LMS's
	/// reply puts the same level back on the device, so nothing echoes.
	private func deviceVolumeChanged(_ report: VolumeReport) {
		guard let server = lms.server else {
			// a held key reports many times a second: say it once
			if Date().timeIntervalSince(lastNoServerLog) > 5 {
				lastNoServerLog = Date()
				log("the Mac's volume changed, but no server is known yet; not sent")
			}
			return
		}
		volumeSender.submit(VolumeChange(report: report, server: server, mac: mac))
	}

	private func engineExited(pid: Int32, status: Int32) {
		if pid == expectedExit {
			expectedExit = nil
			return
		}
		guard engine?.processIdentifier == pid else { return }
		engine = nil
		engineArgs = nil
		engineDevice = nil
		engineFormat = nil
		try? FileManager.default.removeItem(at: Paths.enginePID)
		let ran = Date().timeIntervalSince(startedAt)
		if ran > 60 { backoff = 1 }
		log("engine \(pid) exited unexpectedly (status \(status)) after \(Int(ran)) s; restarting in \(Int(backoff)) s")
		problem = "The player engine stopped; restarting"
		scheduleRestart()
	}

	private func scheduleRestart() {
		let work = DispatchWorkItem { [weak self] in self?.reconcile("restart") }
		restartWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
		backoff = min(backoff * 2, 30)
	}

	private func tick() {
		let date = modificationDate(Paths.settings)
		if date != settingsDate {
			settingsDate = date
			let old = settings
			settings = Settings.load()
			if lms.update(setting: settings.server) { // check the new one now, and say what it finds
				lastLMSCheck = .distantPast
				checkLog.settingChanged()
			}
			if settings.playerName != old.playerName {
				// a rename in the app replaces the name file; the engine reads it at start
				try? settings.playerName.write(to: Paths.playerName, atomically: true, encoding: .utf8)
				engineArgs = nil
			}
			reconcile("settings changed")
			// a device's "LMS volume" may have changed: check LMS at once (FixedVolumeSync). A change to or
			// from the device's own volume restarts the engine (-V), and the check in this tick does not
			// sync it (only a connected player is synced): it followed at the next check, 6 s after the
			// change, both ways, live 2026-10-12 (/code-review 2026-10-12, finding 6)
			lastLMSCheck = .distantPast
		}
		// macOS puts its default output back when the engine lets go of a device it held, which
		// reconciles by itself; this catches a different output chosen meanwhile
		if follow.deferred, follow.shouldReconcile(holding: heldDevice()) {
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

	/// finds the server (or uses the configured one) and asks it about this player
	private func refreshLMS() {
		guard !lmsCheckRunning else { return }
		lmsCheckRunning = true
		let configured = lms.setting, mac = self.mac, known = lms.server
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
			var state: LMSClient.PlayerState?
			var answer: TimeInterval?
			if let server = found {
				let asked = clock.now
				state = await LMSClient(server: server).playerState(mac: mac)
				answer = asked.duration(to: clock.now) / .seconds(1)
			}
			let checked = found, took = began.duration(to: clock.now) / .seconds(1)
			DispatchQueue.main.async {
				guard let self else { return }
				self.lmsCheckRunning = false
				// unreachable: look again next time. Begun before the server setting changed: dropped,
				// and the new one is checked at the next tick, not 5 s after this check began
				let kept = self.lms.checked(setting: configured, found: state == nil ? nil : checked, state: state)
				if !kept { self.lastLMSCheck = .distantPast }
				// how a stalled server is seen: slow checks, dropped ones and the server used (LMSCheckLog)
				let end: LMSCheckLog.End = kept ? .kept(answered: state != nil, answer: answer)
					: .dropped(began: configured, now: self.lms.setting, took: took)
				for line in self.checkLog.ended(end, found: checked) { log(line) }
				if kept, let state, state.connected, let server = checked { self.syncFixedVolume(state, server: server) }
			}
		}
	}

	/// LMS's "Output level fixed at 100%" for this player follows the "LMS volume" setting of the
	/// device the engine plays to (FixedVolumeSync). `status` already carries the pref, so this costs
	/// requests only when LMS differs: the send, a read of what LMS kept, and the saved volume before
	/// and after (put back when LMS's hook changed it, `volumeRestore`).
	private func syncFixedVolume(_ state: LMSClient.PlayerState, server: LMSServer) {
		guard let device = engineDevice else { return }
		let mode = settings.options(for: device).volume, uid = device.uid, name = device.name
		guard let command = fixedVolume.withLock({ $0.checked(device: uid, mode: mode, lms: state.digitalVolumeControl) }) else { return }
		log("LMS volume for \(name): \(mode == .fixed ? "setting it to fixed at 100%" : "turning volume control back on"), as this device's setting says")
		let mac = self.mac, sync = fixedVolume
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
		status.engineRunning = engine?.isRunning ?? false
		status.enginePID = engine?.processIdentifier
		status.devices = devices
		// the device actually played to, which can differ from the macOS output (follow.deferred)
		if let device = engineDevice ?? settings.resolveDevice(in: devices) {
			status.deviceUID = device.uid
			status.deviceName = device.name
			if let id = CoreAudioQuery.device(uid: device.uid) {
				status.currentRate = CoreAudioQuery.nominalRate(id)
				status.currentFormat = CoreAudioQuery.physicalFormat(id)
				status.dsdRate = engineFormat?.dsdRate(deviceRate: status.currentRate)
				if let owner = CoreAudioQuery.hogOwner(id), let pid = status.enginePID {
					status.exclusive = owner == pid
				}
			}
		}
		status.serverName = lms.server?.name ?? lms.server?.host
		status.connected = lms.playerState?.connected ?? false
		status.mode = lms.playerState?.mode
		status.nowPlaying = lms.playerState?.nowPlaying
		status.problem = problem
		try? status.save()
	}

	private func shutdown(_ sig: Int32) {
		shuttingDown = true
		log("signal \(sig): stopping")
		stopEngine()
		problem = nil
		lms.forgetPlayer()
		writeStatus()
		exit(0) // a clean exit: launchd's KeepAlive{SuccessfulExit=false} leaves us stopped
	}
}

// held for the life of the process: run() never returns, and its callbacks capture it weakly
let supervisor = Supervisor()
supervisor.run()
