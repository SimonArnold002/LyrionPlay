// The LyrionPlay menu bar app: switches the player (the launch agent) on and off, shows what
// it is doing, and edits its settings. It reads status.json and writes settings.json. It is tied
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

	/// the device the player holds exclusively, which "Follow the macOS output" stays on
	/// (Settings.resolveDevice)
	var heldDevice: String? {
		guard agentAlive, let status, status.exclusive else { return nil }
		return status.deviceUID
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

	/// false when the file could not be written (lastError says why)
	@discardableResult
	func save(_ draft: PlayerCore.Settings) -> Bool {
		// a saved volume choice a device does not offer is read as one it does (Settings.options(for:));
		// write that, for the devices here
		var draft = draft
		for device in devices where draft.devices[device.uid] != nil {
			draft.devices[device.uid] = draft.options(for: device)
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
				StatusRows(status: status)
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
	let status: AgentStatus

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Label(serverLine, systemImage: status.connected ? "checkmark.circle.fill" : "circle.dashed")
			if let device = status.deviceName {
				Label(outputLine(device), systemImage: status.exclusive ? "lock.fill" : "speaker.wave.2")
			}
			if let track = status.nowPlaying, let mode = status.mode, mode != "stop" {
				Label(track, systemImage: mode == "play" ? "play.fill" : "pause.fill")
					.lineLimit(2)
			}
			if let problem = status.problem {
				Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
			}
		}
		.font(.callout)
	}

	private var serverLine: String {
		if status.connected { return "Connected to \(status.serverName ?? "LMS")" }
		if let name = status.serverName { return "Connecting to \(name)…" }
		return "Looking for the server…"
	}

	private func outputLine(_ device: String) -> String {
		var parts = [device]
		if let dsd = status.dsdRate {
			// DoP: the device runs at the DSD rate / 16 in a 32-bit word, so show the DSD
			parts.append(DeviceCaps.dsd(dsd))
			parts.append("DoP")
		} else {
			if let rate = status.currentRate { parts.append(DeviceCaps.kHz(rate)) }
			if let format = status.currentFormat { parts.append(format) }
		}
		if status.exclusive { parts.append("exclusive") }
		return parts.joined(separator: " · ")
	}
}

struct SettingsView: View {
	@Bindable var model: PlayerModel
	@Environment(\.dismissWindow) private var dismissWindow

	var body: some View {
		Form {
			Section("Player") {
				TextField("Name", text: $model.draft.playerName)
				TextField("Server", text: $model.draft.server, prompt: Text("Find automatically"))
			}
			Section("Output") {
				Picker("Device", selection: $model.draft.outputDevice) {
					Text("Follow the macOS output").tag(PlayerCore.Settings.followSystem)
					ForEach(model.devices) { device in
						Text("\(device.name) (\(device.rateSummary))").tag(device.uid)
					}
				}
				if let device = model.draft.resolveDevice(in: model.devices, holding: model.heldDevice) {
					Toggle("Exclusive mode", isOn: option(device, \.exclusive))
					Text(model.draft.idleSeconds == 0
						 ? "Other apps cannot use \(device.name) while the player is on: it is never released (Advanced)."
						 : "Other apps cannot use \(device.name) while the player is playing.")
						.font(.caption).foregroundStyle(.secondary)
					Toggle("DAC accepts DSD over PCM (DoP)", isOn: option(device, \.dop))
					Text("Off: DSD is converted to PCM in the player, so it still plays.")
						.font(.caption).foregroundStyle(.secondary)
					// only what the device offers (VolumeMode.offered): no device volume without a control,
					// no Fixed on the Mac's own outputs
					Picker("LMS volume", selection: option(device, \.volume)) {
						ForEach(VolumeMode.offered(by: device), id: \.self) { mode in
							switch mode {
							case .device: Text("Device's own volume").tag(mode)
							case .software: Text("Software (scales the samples)").tag(mode)
							case .fixed: Text("Fixed at 100%").tag(mode)
							}
						}
					}
					// the player's "Output level fixed at 100%" in LMS follows this (FixedVolumeSync)
					Text(volumeCaption(device))
						.font(.caption).foregroundStyle(.secondary)
					Stepper("Silence on a rate change: \(model.draft.options(for: device).rateSwitchDelayMs) ms",
							value: option(device, \.rateSwitchDelayMs), in: 0...2000, step: 100)
				}
			}
			Section("Advanced") {
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
		.onAppear {
			model.clearSaveError() // from an earlier opening
			model.loadDevices()
			// what is saved now (the volume warning compares with it; Revert goes back to it)
			model.settings = PlayerCore.Settings.load()
			model.draft = model.settings
		}
	}

	/// Under "LMS volume". The Mac's volume keys change only the macOS output's level, in every mode
	/// (LyrionPlay never sees a key), so where they work is said for any device with a volume control;
	/// not under Fixed, where it would confuse (Simon, 2026-10-12). Fixed warns that it is louder only
	/// when the saved mode scales the samples (software volume, VolumeMode.scalesSamples): from the
	/// device's own volume the level stays.
	private func volumeCaption(_ device: DeviceCaps) -> String {
		let keys = " The Mac's volume keys work only when the output is the Mac's built-in speakers or Follow the macOS output."
		switch model.draft.options(for: device).volume {
		case .device: // offered only with a volume control (VolumeMode.offered)
			// "fixed" is never said here: nothing is fixed in these modes (Simon, 2026-10-12)
			return "The LMS volume slider sets \(device.name)'s own volume." + keys
		case .software:
			return "The LMS volume slider scales the samples; \(device.name)'s own volume stays where it is."
				+ (device.volume != nil ? keys : "")
		case .fixed:
			break
		}
		var caption = device.volume == nil
			? "LMS sends full level; set the volume on \(device.name) or your amplifier."
			: "LMS sends full level and leaves \(device.name)'s own volume alone."
		if model.settings.options(for: device).volume.scalesSamples {
			caption += " From software volume this is louder: turn it down before saving."
		}
		return caption
	}

	private func option<T>(_ device: DeviceCaps, _ key: WritableKeyPath<DeviceOptions, T>) -> Binding<T> {
		Binding(
			get: { model.draft.options(for: device)[keyPath: key] },
			set: { value in
				var options = model.draft.options(for: device)
				options[keyPath: key] = value
				model.draft.devices[device.uid] = options
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
