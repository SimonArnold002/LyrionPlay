// The LyrionPlay menu bar app: switches the player (the launch agent) on and off, shows what
// each player is doing, and edits their settings. It reads status.json and writes settings.json. It is tied
// to the player: Quit stops the player, and the agent reopens the menu if it dies (AppDelegate).
//
// No @State anywhere: the Command Line Tools ship the Observation macros but not SwiftUI's macro
// plugin (SwiftUIMacros), which @State needs in the macOS 26 SDK. State lives in PlayerModel.
import AppKit
import PlayerCore
import SwiftUI

@main
struct LyrionPlayApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	private let model: PlayerModel

	init() {
		// One menu at a time. A second copy (the agent and Finder opening it together, or a copy
		// in another folder) leaves at once, before any UI, and leaves the player alone.
		if !MenuPresence.claim() { exit(0) }
		model = PlayerModel.shared
	}

	var body: some Scene {
		MenuBarExtra {
			MenuView(model: model)
		} label: {
			Image(nsImage: model.isOn ? MenuBarIcon.on : MenuBarIcon.off)
				.renderingMode(.template)
		}
		.menuBarExtraStyle(.window)

		Window("LyrionPlay Settings", id: "settings") {
			SettingsView(model: model)
		}
		.windowResizability(.contentSize)
		// The open panel keeps the keyboard while another app is in front, so ⌘Q meant for that
		// app quit this one (2026-10-09, 22:48:51; see the ledger, A SHORTCUT QUIT THE MENU). Now that
		// quitting stops the player too, Quit in the panel is the only way out.
		.commands { CommandGroup(replacing: .appTermination) {} }
	}
}

/// The menu and the player are tied (Simon, 2026-10-09). Quitting the menu stops the player, and
/// opening the menu starts a player that is on. While the player runs, the agent reopens a menu
/// that crashed or was force-quit (MenuPresence).
final class AppDelegate: NSObject, NSApplicationDelegate {
	/// set by Quit, so the log can tell a chosen quit from any other request
	static var quitChosen = false

	/// kAEQuitReason, a parameter of the quit Apple event, and the values that mean the session
	/// is ending (AERegistry.h: kAEQuitAll, kAEReallyLogOut, kAELogOut, kAERestart, kAEShutDown,
	/// kAEShowRestartDialog, kAEShowShutdownDialog)
	private static let quitReasonKeyword: AEKeyword = 0x7768_793F // 'why?'
	private static let sessionEndReasons: Set<OSType> = [
		0x7175_6961, 0x726C_676F, 0x6C6F_676F, 0x7265_7374, 0x7368_7574, 0x7272_7374, 0x7273_646E,
	] // 'quia' 'rlgo' 'logo' 'rest' 'shut' 'rrst' 'rsdn'

	func applicationDidFinishLaunching(_ notification: Notification) {
		try? FileManager.default.removeItem(at: MenuPresence.sessionEnding)
		do {
			try LaunchAgent.startIfOn(agent: Paths.executable("lyrionplay-agent"))
		} catch {
			menuLog("could not start the player: \(error.localizedDescription)")
		}
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

	/// A quit is never refused: logout, restart and shutdown need it.
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		let appleEvent = NSAppleEventManager.shared().currentAppleEvent
		let reason = appleEvent?.paramDescriptor(forKeyword: Self.quitReasonKeyword)?.enumCodeValue
			?? appleEvent?.attributeDescriptor(forKeyword: Self.quitReasonKeyword)?.enumCodeValue
		if let reason, Self.sessionEndReasons.contains(reason) {
			// launchd stops the player with the session, and the plist starts both again at login.
			// The marker keeps the agent from reopening the menu in the meantime.
			try? Data().write(to: MenuPresence.sessionEnding)
			menuLog("menu app quit: the session is ending (reason \(reason))")
			return .terminateNow
		}
		if !Self.quitChosen {
			// anything other than Quit: logged with its cause, in case something unexpected sends one
			var cause = "no event"
			if let event = NSApp.currentEvent {
				cause = "event type \(event.type.rawValue)"
				if event.type == .keyDown {
					cause += ", key '\(event.charactersIgnoringModifiers ?? "")', modifiers \(event.modifierFlags.rawValue)"
				}
			}
			if let appleEvent { cause += ", Apple event \(appleEvent.eventID)" }
			menuLog("menu app quit, not from Quit: \(cause); stopping the player")
		}
		// the agent is stopped before this app exits, so it cannot reopen the menu
		LaunchAgent.stop()
		return .terminateNow
	}

	private func menuLog(_ text: String) {
		let line = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(text)\n"
		try? Paths.createDirectories()
		let url = Paths.logs.appendingPathComponent("menu.log")
		if let handle = try? FileHandle(forWritingTo: url) {
			handle.seekToEndOfFile()
			handle.write(Data(line.utf8))
			try? handle.close()
		} else {
			try? Data(line.utf8).write(to: url)
		}
	}
}

@MainActor @Observable
final class PlayerModel {
	static let shared = PlayerModel()

	var isOn = LaunchAgent.isOn
	var status: AgentStatus?
	var settings = PlayerCore.Settings.load()
	/// the settings window edits this copy; Save writes it
	var draft = PlayerCore.Settings.load()
	var devices: [DeviceCaps] = []
	var lastError: String?
	/// a failed save, shown in the Settings window itself (Simon, 2026-10-12); lastError still carries
	/// it to the menu panel
	var saveError: String?
	/// the player whose settings page (the cog) is open
	var editingPlayer: String?
	/// Fixed on a device with a volume control: what reading LMS's volume gave, while there is no level
	/// to hold (reading, or why not), by player
	var heldNote: [String: String] = [:]
	@ObservationIgnored private var timer: Timer?

	init() {
		refresh()
		timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.refresh() }
		}
	}

	func refresh() {
		isOn = LaunchAgent.isOn
		status = AgentStatus.load()
		if isOn, let status, !status.devices.isEmpty { devices = status.devices }
	}

	/// the device *Follow the macOS output* holds exclusively, which it stays on (Settings.followDevice)
	var heldFollowDevice: String? {
		guard agentAlive, let player = status?.player(PlayerKey.follow), player.exclusive else { return nil }
		return player.deviceUID
	}

	/// the Settings list: *Follow the macOS output*, then every device but the Mac's built-in outputs
	var rows: [PlayerRow] {
		PlayerList.rows(settings: draft, devices: devices, holding: heldFollowDevice)
	}

	/// the agent writes status every 2 s; older than 10 s means it is not running
	var agentAlive: Bool {
		guard let status else { return false }
		return Date().timeIntervalSince(status.updated) < 10
	}

	func setOn(_ on: Bool) {
		// A quarantined copy opened where it was downloaded runs from a temporary read-only path
		// (App Translocation). The launch agent would record that path, and it is gone after a
		// restart, so the player would never start again.
		if on, Paths.appBundle.path.contains("/AppTranslocation/") {
			lastError = "Install LyrionPlay with install.sh first: it is running from a temporary copy."
			return
		}
		do {
			try Paths.createDirectories()
			if on {
				try LaunchAgent.turnOn(agent: Paths.executable("lyrionplay-agent"))
			} else {
				LaunchAgent.turnOff()
			}
			lastError = nil
		} catch {
			lastError = error.localizedDescription
		}
		refresh()
	}

	func loadDevices() {
		let probed = DeviceCaps.probe(engine: Paths.executable("squeezelite"))
		if !probed.isEmpty { devices = probed }
	}

	/// The LMS volume picker. Fixed on a device with a volume control holds the volume LMS has saved
	/// for the player now (FIXED HOLDS THE LMS VOLUME): read here, and shown before the save. The level
	/// is read again only when Fixed is chosen again; another mode drops it.
	func chooseVolume(_ mode: VolumeMode, for row: PlayerRow) {
		var player = draft.player(row.key, device: row.device)
		player.volume = mode
		player.heldVolume = nil
		draft.players[row.key] = player
		heldNote[row.key] = nil
		guard mode == .fixed, let device = row.device, device.volume != nil else { return }
		guard let server = statusServer else {
			heldNote[row.key] = "LyrionPlay is not connected to LMS, so the volume to hold is not known: Fixed is not saved."
			return
		}
		guard let mac = (try? String(contentsOf: Paths.mac(row.key), encoding: .utf8))?
				.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), PlayerIdentity.isValid(mac) else {
			heldNote[row.key] = "LMS does not know this player yet: switch it on, let it connect, set its volume in LMS, then choose Fixed."
			return
		}
		heldNote[row.key] = "Reading the volume LMS has for this player…"
		let key = row.key
		Task {
			let volume = await LMSClient(server: server).volume(player: mac)
			// chosen again, or another mode, meanwhile: this answer is not wanted
			guard heldNote[key] == "Reading the volume LMS has for this player…", draft.players[key]?.volume == .fixed else { return }
			switch HeldVolume.from(lmsVolume: volume) {
			case .held(let level):
				draft.players[key]?.heldVolume = level
				heldNote[key] = nil
			case .refused(let reason):
				heldNote[key] = reason
			}
		}
	}

	private var statusServer: LMSServer? {
		guard agentAlive, let status, let host = status.serverHost, let port = status.serverWebPort else { return nil }
		return LMSServer(host: host, webPort: port, name: status.serverName)
	}

	/// false when the file could not be written, or Fixed has no level to hold (lastError says why)
	@discardableResult
	func save(_ draft: PlayerCore.Settings) -> Bool {
		// a saved volume choice a device does not offer is read as one it does (Settings.player);
		// write that, for the players shown here, but Follow's as saved (Settings.forSaving)
		var draft = draft
		for row in rows where draft.players[row.key] != nil {
			draft.players[row.key] = draft.forSaving(row.key, device: row.device)
		}
		for row in rows {
			guard let device = row.device, device.volume != nil, draft.players[row.key] != nil else { continue }
			let player = draft.player(row.key, device: device)
			guard player.volume == .fixed, player.heldVolume == nil else { continue }
			lastError = "\(player.name): Fixed has no level to hold. \(heldNote[row.key] ?? "Choose Fixed again.")"
			saveError = lastError
			return false
		}
		do {
			try Paths.createDirectories()
			try draft.save()
			settings = draft
			// only a failed save's message: a switch-on error stays, as at Revert (/code-review
			// 2026-10-12 (6), finding 1)
			clearSaveError()
			return true
		} catch {
			lastError = "Could not save the settings: \(error.localizedDescription)"
			saveError = lastError
			return false
		}
	}

	/// back to what is saved, and a failed save's message with it, in the window and in the menu
	/// panel; a switch-on error in lastError stays (/code-review 2026-10-12 (2), finding 4)
	func revert() {
		draft = settings
		heldNote = [:]
		clearSaveError()
	}

	func clearSaveError() {
		if saveError != nil, lastError == saveError { lastError = nil }
		saveError = nil
	}
}

struct MenuView: View {
	@Bindable var model: PlayerModel
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Text("LyrionPlay").font(.headline)
				Spacer()
				Toggle("Player", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
					.toggleStyle(.switch)
					.labelsHidden()
			}
			if !model.isOn {
				Text("The player is off.").foregroundStyle(.secondary)
			} else if !model.agentAlive {
				Text("Starting…").foregroundStyle(.secondary)
			} else if let status = model.status {
				if let problem = status.problem {
					Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
				}
				if status.players.isEmpty {
					Text("No player is on: switch one on in Settings.").foregroundStyle(.secondary)
				}
				// one block per player that is on (Simon, 2026-10-12)
				ForEach(status.players, id: \.key) { player in
					VStack(alignment: .leading, spacing: 6) {
						Text(player.name).font(.callout.bold())
						StatusRows(player: player, serverName: status.serverName)
					}
				}
			}
			if let error = model.lastError {
				Text(error).font(.caption).foregroundStyle(.red)
			}
			Divider()
			HStack {
				Button("Settings…") {
					openWindow(id: "settings")
					NSApp.activate(ignoringOtherApps: true)
				}
				Button("Logs") { NSWorkspace.shared.open(Paths.logs) }
				Spacer()
				Button("Quit") {
					AppDelegate.quitChosen = true
					NSApp.terminate(nil)
				}
			}
			Text("Quit stops the player too. Both start again at login, or when you open LyrionPlay.")
				.font(.caption2)
				.foregroundStyle(.secondary)
			Text("Version \(AppVersion.version)")
				.help("Build \(AppVersion.build)")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.padding(14)
		.frame(width: 330)
	}
}

struct StatusRows: View {
	let player: PlayerStatus
	let serverName: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Label(serverLine, systemImage: player.connected ? "checkmark.circle.fill" : "circle.dashed")
			if let device = player.deviceName {
				Label(outputLine(device), systemImage: player.exclusive ? "lock.fill" : "speaker.wave.2")
			}
			if let track = player.nowPlaying, let mode = player.mode, mode != "stop" {
				Label(track, systemImage: mode == "play" ? "play.fill" : "pause.fill")
					.lineLimit(2)
			}
			if let problem = player.problem {
				Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
			}
		}
		.font(.callout)
	}

	private var serverLine: String {
		if player.connected { return "Connected to \(serverName ?? "LMS")" }
		if let name = serverName { return "Connecting to \(name)…" }
		return "Looking for the server…"
	}

	private func outputLine(_ device: String) -> String {
		var parts = [device]
		if let dsd = player.dsdRate {
			// DoP: the device runs at the DSD rate / 16 in a 32-bit word, so show the DSD
			parts.append(DeviceCaps.dsd(dsd))
			parts.append("DoP")
		} else {
			if let rate = player.currentRate { parts.append(DeviceCaps.kHz(rate)) }
			if let format = player.currentFormat { parts.append(format) }
		}
		if player.exclusive { parts.append("exclusive") }
		return parts.joined(separator: " · ")
	}
}

/// The Settings window: the players, each with its switch and its cog, then what they share
/// (Simon, 2026-10-12).
struct SettingsView: View {
	@Bindable var model: PlayerModel
	@Environment(\.dismissWindow) private var dismissWindow

	var body: some View {
		Form {
			Section("Players") {
				ForEach(model.rows) { row in
					PlayerRowView(model: model, row: row)
				}
				Text("Each player is its own player in LMS, with its own volume and settings.")
					.font(.caption).foregroundStyle(.secondary)
			}
			Section("Shared") {
				TextField("Server", text: $model.draft.server, prompt: Text("Find automatically"))
				// 0 passes no -C (EngineArguments): the engine opens the device at start and keeps it
				Stepper(model.draft.idleSeconds == 0 ? "Release the device: never"
							: "Release the device after \(model.draft.idleSeconds) s stopped",
						value: $model.draft.idleSeconds, in: 0...600, step: 5)
				Picker("Resampling quality", selection: $model.draft.resampleQuality) {
					Text("Very high").tag("v")
					Text("High").tag("h")
					Text("Medium").tag("m")
				}
				Picker("Log detail", selection: $model.draft.logLevel) {
					Text("Normal").tag("info")
					Text("Debug").tag("debug")
				}
			}
			if let error = model.saveError {
				Text(error).font(.caption).foregroundStyle(.red)
			}
			HStack {
				Spacer()
				Button("Revert") { model.revert() }
				Button("Save") { model.save(model.draft) }
					.keyboardShortcut(.defaultAction)
				// closes only when the save worked, so a failed one keeps the edits on screen
				Button("Save and Close") {
					if model.save(model.draft) { dismissWindow(id: "settings") }
				}
			}
		}
		.formStyle(.grouped)
		.frame(width: 500)
		.sheet(item: Binding(get: { model.rows.first { $0.key == model.editingPlayer } },
							 set: { model.editingPlayer = $0?.key })) { row in
			PlayerSettingsView(model: model, row: row)
		}
		.onAppear {
			model.clearSaveError() // from an earlier opening
			model.loadDevices()
			// what is saved now (the volume warning compares with it; Revert goes back to it)
			model.settings = PlayerCore.Settings.load()
			model.draft = model.settings
			model.heldNote = [:]
		}
	}
}

/// One player in the list: its name and device, its switch, and its cog.
struct PlayerRowView: View {
	@Bindable var model: PlayerModel
	let row: PlayerRow

	var body: some View {
		let player = model.draft.player(row.key, device: row.device)
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				Text(row.isFollow ? "Follow the macOS output" : player.name)
				Text(subtitle(player)).font(.caption).foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("On", isOn: Binding(
				get: { model.draft.isOn(row.key) },
				set: { on in
					var player = model.draft.forSaving(row.key, device: row.device)
					player.enabled = on
					model.draft.players[row.key] = player
				}))
				.toggleStyle(.switch)
				.labelsHidden()
			Button {
				model.editingPlayer = row.key
			} label: {
				Image(systemName: "gearshape")
			}
			.buttonStyle(.borderless)
			.help("Settings for this player")
		}
	}

	private func subtitle(_ player: PlayerSettings) -> String {
		guard let device = row.device else { return row.isFollow ? "No output device" : "Not connected" }
		return row.isFollow ? "\(player.name), now on \(device.name) (\(device.rateSummary))" : device.rateSummary
	}
}

/// A player's settings, behind its cog: today's per-device settings, for this player.
struct PlayerSettingsView: View {
	@Bindable var model: PlayerModel
	let row: PlayerRow

	var body: some View {
		Form {
			Section(row.isFollow ? "Follow the macOS output" : (row.device?.name ?? model.draft.player(row.key, device: nil).name)) {
				TextField("Name", text: setting(\.name))
				if let device = row.device {
					Toggle("Exclusive mode", isOn: setting(\.exclusive))
					// macOS moves its own output away from a device held exclusively, so the keys move that one
					// (HOG MOVES THE DEFAULT OUTPUT; THE MAC'S VOLUME AND EXCLUSIVE MODE, Simon 2026-10-14)
					Text((model.draft.idleSeconds == 0
						  ? "Other apps cannot use \(device.name) while the player is on: it is never released (Shared)."
						  : "Other apps cannot use \(device.name) while the player is playing.")
						 + " Meanwhile macOS sends its own sound to another output, so the Mac's volume keys don't change \(device.name).")
						.font(.caption).foregroundStyle(.secondary)
					Toggle("DAC accepts DSD over PCM (DoP)", isOn: setting(\.dop))
					Text(dopCaption(device))
						.font(.caption).foregroundStyle(.secondary)
					// only what the device offers (VolumeMode.offered): no device volume without a control,
					// no Fixed on the Mac's own outputs or for *Follow the macOS output*
					Picker("LMS volume", selection: Binding(
						get: { model.draft.player(row.key, device: device).volume },
						set: { model.chooseVolume($0, for: row) })) {
						ForEach(VolumeMode.offered(by: device, follow: row.isFollow), id: \.self) { mode in
							switch mode {
							case .device: Text("Device's own volume").tag(mode)
							case .software: Text("Software (scales the samples)").tag(mode)
							case .fixed: Text("Fixed").tag(mode)
							}
						}
					}
					// the player's "Output level fixed at 100%" in LMS follows this (FixedVolumeSync)
					Text(volumeCaption(device))
						.font(.caption).foregroundStyle(.secondary)
					Stepper("Silence on a rate change: \(model.draft.player(row.key, device: device).rateSwitchDelayMs) ms",
							value: setting(\.rateSwitchDelayMs), in: 0...2000, step: 100)
				} else {
					Text(row.isFollow ? "There is no macOS output to follow." : "Connect it to change its settings.")
						.font(.caption).foregroundStyle(.secondary)
				}
			}
			HStack {
				Spacer()
				Button("Done") { model.editingPlayer = nil }
					.keyboardShortcut(.defaultAction)
			}
		}
		.formStyle(.grouped)
		.frame(width: 460)
	}

	/// Under the DoP switch. DoP plays at full scale whatever LMS's level (upstream output.c: the gain
	/// is FIXED_ONE for any output that is not PCM), so where LMS's volume scales the samples (software)
	/// the slider does nothing to DSD sent as DoP (Simon, 2026-10-14: "you can still control the volume
	/// but it doesnt do anything at all"). The device's own volume and Fixed are not affected.
	private func dopCaption(_ device: DeviceCaps) -> String {
		let player = model.draft.player(row.key, device: device)
		let caption = "Off: DSD is converted to PCM in the player, so it still plays."
		guard player.dop, player.volume.scalesSamples else { return caption }
		return caption + " DSD sent as DoP always plays at full level: the LMS slider doesn't change it. Use the DAC's own volume."
	}

	/// Under "LMS volume". The Mac's volume keys change only the macOS output's level, in every mode
	/// (LyrionPlay never sees a key), so where they work is said for any device with a volume control;
	/// not under Fixed, where it would confuse (Simon, 2026-10-12). Fixed warns that it is louder only
	/// when the saved mode scales the samples (software volume, VolumeMode.scalesSamples): from the
	/// device's own volume it holds the level LMS had.
	private func volumeCaption(_ device: DeviceCaps) -> String {
		// exclusive mode moves the macOS output to another device, so the keys move that one (HOG MOVES
		// THE DEFAULT OUTPUT; Simon, 2026-10-14)
		let keys = " The Mac's volume keys work only when the output is the Mac's built-in speakers or Follow the macOS output, with Exclusive mode off."
		let player = model.draft.player(row.key, device: device)
		switch player.volume {
		case .device: // offered only with a volume control (VolumeMode.offered)
			// "fixed" is never said here: nothing is fixed in these modes (Simon, 2026-10-12)
			return "The LMS volume slider sets \(device.name)'s own volume." + keys
		case .software: // offered only without a volume control (VolumeMode.offered), so no keys note
			return "The LMS volume slider scales the samples; \(device.name)'s own volume stays where it is."
		case .fixed:
			break
		}
		var caption: String
		if device.volume == nil {
			caption = "LMS sends full level; set the volume on \(device.name) or your amplifier."
		} else if let held = player.heldVolume {
			caption = "LMS sends full level; \(device.name) holds LMS volume \(held) (\(String(format: "%.1f", HeldVolume.dB(held))) dB). To change it, choose Device's own volume, set the volume in LMS, then Fixed again."
		} else {
			caption = model.heldNote[row.key] ?? "Choose Fixed again to read the volume LMS has for this player."
		}
		if model.settings.player(row.key, device: device).volume.scalesSamples {
			caption += " From software volume this is louder."
		}
		return caption
	}

	private func setting<T>(_ key: WritableKeyPath<PlayerSettings, T>) -> Binding<T> {
		Binding(
			get: { model.draft.player(row.key, device: row.device)[keyPath: key] },
			set: { value in
				var player = model.draft.forSaving(row.key, device: row.device)
				player[keyPath: key] = value
				model.draft.players[row.key] = player
			})
	}
}

/// The menu bar icon: LyrionPlay.svg (Material's play arrow leading into Lyrion's waveform) as a
/// template image, so macOS colours it for a light or dark menu bar. Dimmed while the player is off.
enum MenuBarIcon {
	static let on = make(alpha: 1)
	static let off = make(alpha: 0.4)

	private static func make(alpha: CGFloat) -> NSImage {
		guard let url = Bundle.main.url(forResource: "LyrionPlay", withExtension: "svg"),
			  let glyph = NSImage(contentsOf: url), glyph.size.height > 0 else {
			return NSImage(systemSymbolName: "play.fill", accessibilityDescription: "LyrionPlay") ?? NSImage()
		}
		let height: CGFloat = 16
		let size = NSSize(width: height * glyph.size.width / glyph.size.height, height: height)
		let image = NSImage(size: size, flipped: false) { rect in
			glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
			return true
		}
		image.isTemplate = true
		image.accessibilityDescription = "LyrionPlay"
		return image
	}
}
