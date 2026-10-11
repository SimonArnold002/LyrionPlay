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

	func save(_ draft: PlayerCore.Settings) {
		do {
			try Paths.createDirectories()
			try draft.save()
			settings = draft
			lastError = nil
		} catch {
			lastError = "Could not save the settings: \(error.localizedDescription)"
		}
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
		if let rate = status.currentRate { parts.append(DeviceCaps.kHz(rate)) }
		if let format = status.currentFormat { parts.append(format) }
		if status.exclusive { parts.append("exclusive") }
		return parts.joined(separator: " · ")
	}
}

struct SettingsView: View {
	@Bindable var model: PlayerModel

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
					Text("Other apps cannot use \(device.name) while the player is playing.")
						.font(.caption).foregroundStyle(.secondary)
					Toggle("DAC accepts DSD over PCM (DoP)", isOn: option(device, \.dop))
					Text("Off: DSD is converted to PCM in the player, so it still plays.")
						.font(.caption).foregroundStyle(.secondary)
					Picker("LMS volume", selection: option(device, \.volume)) {
						Text(device.volume == nil ? "Device volume (none here: software is used)" : "Device's own volume")
							.tag(VolumeMode.device)
						Text("Software (scales the samples)").tag(VolumeMode.software)
					}
					Stepper("Silence on a rate change: \(model.draft.options(for: device).rateSwitchDelayMs) ms",
							value: option(device, \.rateSwitchDelayMs), in: 0...2000, step: 100)
				}
			}
			Section("Advanced") {
				Stepper("Release the device after \(model.draft.idleSeconds) s stopped",
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
			HStack {
				Spacer()
				Button("Revert") { model.draft = model.settings }
				Button("Save") { model.save(model.draft) }
					.keyboardShortcut(.defaultAction)
			}
		}
		.formStyle(.grouped)
		.frame(width: 500)
		.onAppear {
			model.loadDevices()
			model.draft = PlayerCore.Settings.load()
		}
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
