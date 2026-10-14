import Foundation
import Testing
@testable import PlayerCore

// Real `squeezelite -l` output from Simon's Mac, 2026-10-09, plus a line the parser must skip.
let probeOutput = """
	{"uid":"AppleUSBAudioEngine:FiiO:FiiO M11 Plus:3fa90f5:1","name":"FiiO M11 Plus","manufacturer":"FiiO","transport":"usb","default":false,"channels":2,"rates":[384000,352800,192000,176400,96000,88200,48000,44100,32000],"integer_bits":[32],"float":false,"volume":null,"exclusive_owner":-1,"current_rate":48000,"current_format":"32-bit integer"}
	not a device line
	{"uid":"BuiltInSpeakerDevice","name":"MacBook Pro Speakers","manufacturer":"Apple Inc.","transport":"builtin","default":true,"channels":2,"rates":[96000,88200,48000,44100],"integer_bits":[],"float":true,"volume":{"control":"main","db_min":-63.50,"db_max":0.00,"mute":true},"exclusive_owner":-1,"current_rate":44100,"current_format":"32-bit float"}
	"""

let devices = DeviceCaps.parseList(probeOutput)
var fiio: DeviceCaps { devices.first { $0.name == "FiiO M11 Plus" }! }
var speakers: DeviceCaps { devices.first { $0.uid == "BuiltInSpeakerDevice" }! }
// a DAC WITH a volume control: Simon's DragonFly, from the agent's probe in status.json, 2026-10-12
var dragonfly: DeviceCaps {
	DeviceCaps.parseList("""
		{"uid":"AppleUSBAudioEngine:AudioQuest:AudioQuest DragonFly Black v1.5:AQDFBL0100009556:1","name":"AudioQuest DragonFly Black v1.5","manufacturer":"AudioQuest","transport":"usb","default":false,"channels":2,"rates":[96000,88200,48000,44100],"integer_bits":[24],"float":false,"volume":{"control":"main","db_min":-64.00,"db_max":0.00,"mute":true},"exclusive_owner":-1,"current_rate":44100,"current_format":"24-bit integer"}
		""").first!
}
// a Mac output with no volume control (HDMI to a display)
var hdmi: DeviceCaps {
	DeviceCaps.parseList("""
		{"uid":"HDMI-1","name":"LG TV","manufacturer":"LG","transport":"hdmi","default":false,"channels":2,"rates":[48000,44100],"integer_bits":[24],"float":false,"volume":null,"exclusive_owner":-1,"current_rate":48000,"current_format":"24-bit integer"}
		""").first!
}

/// a player's engine arguments: the Mac's built-in outputs play through *Follow the macOS output*,
/// every other device through its own player, unless `key` says otherwise
func args(_ settings: Settings, _ device: DeviceCaps, key: String? = nil) -> [String] {
	EngineArguments.build(settings: settings, key: key ?? (device.isBuiltIn ? PlayerKey.follow : device.uid),
						  device: device, mac: "02:00:4c:4d:50:01", nameFile: "/tmp/name", logFile: "/tmp/engine.log")
}

func player(_ device: DeviceCaps, enabled: Bool = true, exclusive: Bool = true, dop: Bool = false,
			volume: VolumeMode, held: Int? = nil, delay: Int = 0) -> PlayerSettings {
	PlayerSettings(enabled: enabled, name: device.name, exclusive: exclusive, dop: dop, volume: volume,
				   heldVolume: held, rateSwitchDelayMs: delay)
}

/// the value after an option, or nil when the option is absent
func value(_ option: String, in a: [String]) -> String? {
	a.firstIndex(of: option).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
}

@Suite struct ProbeParsing {
	@Test func bothDevicesParsedAndTheJunkLineSkipped() {
		#expect(devices.count == 2)
	}

	@Test func fiioCapabilities() {
		#expect(fiio.transport == "usb")
		#expect(fiio.isExternal)
		#expect(fiio.maxRate == 384_000)
		#expect(fiio.volume == nil)
		#expect(!fiio.isDefault)
		#expect(fiio.rateSummary == "32 kHz-384 kHz")
	}

	@Test func speakersCapabilities() {
		#expect(!speakers.isExternal)
		#expect(speakers.isDefault)
		#expect(speakers.volume?.dbMin == -63.5)
		#expect(speakers.maxRate == 96_000)
	}
}

@Suite struct Arguments {
	@Test func speakerDefaultsAreSharedWithDeviceVolume() {
		let a = args(Settings(), speakers)
		#expect(value("-o", in: a) == "BuiltInSpeakerDevice")
		#expect(value("-a", in: a) == "0:0")
		#expect(a.contains("-V"))
		#expect(!a.contains("-D"))
		#expect(value("-Z", in: a) == "96000")
		#expect(value("-R", in: a) == "vE")
		#expect(value("-C", in: a) == "30")
		#expect(value("-s", in: a) == nil) // no server set: discovery
	}

	@Test func fiioDefaultsAreExclusiveWithSoftwareVolume() {
		let a = args(Settings(), fiio)
		#expect(value("-a", in: a) == "0:1")
		#expect(!a.contains("-V")) // no volume control on the device
		#expect(!a.contains("-D")) // DoP is off until switched on
	}

	@Test func dopIsLastBecauseItTakesAnOptionalValue() {
		var settings = Settings()
		settings.players[fiio.uid] = player(fiio, dop: true, volume: .software)
		let a = args(settings, fiio)
		#expect(a.last == "-D")
	}

	@Test func maxSampleRateIsCappedAt384k() {
		var big = fiio
		big.rates = [768_000, 705_600] + big.rates
		#expect(value("-Z", in: args(Settings(), big)) == "384000")
		// control: below the cap the device's own maximum is reported
		#expect(value("-Z", in: args(Settings(), speakers)) == "96000")
	}

	@Test func serverAndIdleAndDelay() {
		var settings = Settings()
		settings.server = "plex"
		settings.idleSeconds = 0
		settings.players[PlayerKey.follow] = player(speakers, exclusive: false, volume: .device, delay: 500)
		let a = args(settings, speakers)
		#expect(value("-s", in: a) == "plex")
		#expect(value("-C", in: a) == nil)
		#expect(value("-r", in: a) == "96000,88200,48000,44100:500")
	}

	// Material keys its Apple player icon on this exact string, under model "squeezelite"
	@Test func modelNameGivesMaterialsAppleIcon() {
		#expect(value("-M", in: args(Settings(), speakers)) == "SqueezeLiteMac")
		#expect(value("-M", in: args(Settings(), fiio)) == "SqueezeLiteMac")
	}

	/// FIXED HOLDS THE LMS VOLUME: Fixed passes -a's fixed field, so the engine itself keeps the
	/// samples at full scale (no -V); on a device with a volume control, with the held level in dB
	/// (LMS volume 17 = -48.83 dB, where the device's own volume puts it: HeldVolumes)
	@Test func fixedIsEnforcedByTheEngineAndHoldsALevel() {
		var settings = Settings()
		settings.players[dragonfly.uid] = player(dragonfly, volume: .fixed, held: 17)
		#expect(!args(settings, dragonfly).contains("-V"))
		#expect(value("-a", in: args(settings, dragonfly)) == "0:1:1:-48.83")
		// no level saved: Fixed, the device left alone (the agent says why)
		settings.players[dragonfly.uid]?.heldVolume = nil
		#expect(value("-a", in: args(settings, dragonfly)) == "0:1:1")
		// a DAC with no volume control holds nothing: its knob sets the level
		settings.players[fiio.uid] = player(fiio, volume: .fixed, held: 17)
		#expect(value("-a", in: args(settings, fiio)) == "0:1:1")
		// controls: the device's own volume, and software (on a DAC with no volume control), are not fixed
		settings.players[dragonfly.uid] = player(dragonfly, volume: .device, held: 17)
		#expect(args(settings, dragonfly).contains("-V"))
		#expect(value("-a", in: args(settings, dragonfly)) == "0:1")
		settings.players[fiio.uid] = player(fiio, volume: .software)
		#expect(!args(settings, fiio).contains("-V"))
		#expect(value("-a", in: args(settings, fiio)) == "0:1")
	}

	/// the Settings window warns that Fixed is louder when the mode being left scales the samples
	/// (/code-review 2026-10-12, finding 2: it had followed the device, not the mode). Since 2026-10-14
	/// software is offered only without a volume control, and saved on one with a control it is read as
	/// the device's own volume, so it no longer warns there.
	@Test func fixedIsLouderOnlyAfterSoftwareVolume() {
		#expect(VolumeMode.software.scalesSamples)
		#expect(!VolumeMode.device.scalesSamples)
		#expect(!VolumeMode.fixed.scalesSamples)
		// the device's own volume saved on a device with no volume control is read as software, so
		// it still warns (/code-review 2026-10-12 (2), finding 3: the rule lives in player(_:device:))
		var saved = Settings()
		saved.players[fiio.uid] = player(fiio, volume: .device)
		#expect(saved.player(fiio.uid, device: fiio).volume.scalesSamples)
		saved.players[dragonfly.uid] = player(dragonfly, volume: .device)
		#expect(!saved.player(dragonfly.uid, device: dragonfly).volume.scalesSamples)
		saved.players[dragonfly.uid] = player(dragonfly, volume: .software)
		#expect(!saved.player(dragonfly.uid, device: dragonfly).volume.scalesSamples)
	}

	/// Simon, 2026-10-12: "block device volume as an option if it doesnt offer it, block fixed on MacOS
	/// outputs" (every output that is not a DAC), and "MacOS 2 options": no Fixed for *Follow the
	/// macOS output*, whatever it follows. Simon, 2026-10-14: no software where the device has a volume
	/// control ("pointless on volume control dacs its purely to add control when there is nothing at all")
	@Test func eachDeviceOffersOnlyWhatItHas() {
		#expect(VolumeMode.offered(by: dragonfly) == [.device, .fixed])    // a DAC with a volume control
		#expect(VolumeMode.offered(by: fiio) == [.software, .fixed])       // a DAC with no volume control
		#expect(VolumeMode.offered(by: speakers) == [.device])             // a Mac output: no Fixed
		#expect(VolumeMode.offered(by: hdmi) == [.software])               // a Mac output with no control
		#expect(VolumeMode.offered(by: dragonfly, follow: true) == [.device])
		// Simon, 2026-10-14: Follow gets Fixed on a DAC with no volume control, so it never holds a level
		#expect(VolumeMode.offered(by: fiio, follow: true) == [.software, .fixed])
		#expect(VolumeMode.offered(by: speakers, follow: true) == [.device])
		#expect(VolumeMode.offered(by: hdmi, follow: true) == [.software])
		// every device offers exactly one of its own volume and software
		for device in [dragonfly, fiio, speakers, hdmi] {
			#expect(VolumeMode.device.isOffered(by: device) != VolumeMode.software.isOffered(by: device))
		}
		// the defaults are always offered
		for device in [dragonfly, fiio, speakers, hdmi] {
			#expect(PlayerSettings.defaults(for: device).volume.isOffered(by: device))
			#expect(Settings().player(PlayerKey.follow, device: device).volume.isOffered(by: device, follow: true))
		}
	}

	/// a choice saved before it was blocked is read as the nearest one offered, by every reader
	/// (Simon's choice), here the engine's arguments
	@Test func aBlockedChoiceSavedIsReadAsOneOffered() {
		var settings = Settings()
		settings.players[PlayerKey.follow] = player(speakers, exclusive: false, volume: .fixed)
		settings.players[fiio.uid] = player(fiio, dop: true, volume: .device)
		settings.players[hdmi.uid] = player(hdmi, exclusive: false, volume: .fixed)
		settings.players[dragonfly.uid] = player(dragonfly, volume: .fixed, held: 17)
		#expect(settings.player(PlayerKey.follow, device: speakers).volume == .device)
		#expect(args(settings, speakers).contains("-V"))
		#expect(settings.player(fiio.uid, device: fiio).volume == .software)
		#expect(!args(settings, fiio).contains("-V"))
		#expect(settings.player(hdmi.uid, device: hdmi).volume == .software)
		// software saved on a device with a volume control (before 2026-10-14): its own volume, with -V
		settings.players[dragonfly.uid] = player(dragonfly, volume: .software)
		#expect(settings.player(dragonfly.uid, device: dragonfly).volume == .device)
		#expect(args(settings, dragonfly).contains("-V"))
		settings.players[PlayerKey.follow] = player(speakers, exclusive: false, volume: .software)
		#expect(settings.player(PlayerKey.follow, device: speakers).volume == .device)
		#expect(args(settings, speakers).contains("-V"))
		settings.players[dragonfly.uid] = player(dragonfly, volume: .fixed, held: 17)
		settings.players[PlayerKey.follow] = player(speakers, exclusive: false, volume: .fixed)
		// the follow player saved as Fixed, now following the DragonFly: its own volume, never Fixed
		#expect(settings.player(PlayerKey.follow, device: dragonfly).volume == .device)
		#expect(value("-a", in: args(settings, dragonfly, key: PlayerKey.follow)) == "0:0")
		// ...and following the FiiO, a DAC with no volume control: Fixed, full level, nothing held
		#expect(settings.player(PlayerKey.follow, device: fiio).volume == .fixed)
		#expect(value("-a", in: args(settings, fiio, key: PlayerKey.follow)) == "0:0:1")
		#expect(!args(settings, fiio, key: PlayerKey.follow).contains("-V"))
		#expect(FixedVolumeSync.value(for: settings.player(PlayerKey.follow, device: fiio).volume) == 0)
		// control: an offered choice is kept, and the rest of the settings with it
		#expect(settings.player(dragonfly.uid, device: dragonfly).volume == .fixed)
		#expect(settings.player(fiio.uid, device: fiio).dop && settings.player(fiio.uid, device: fiio).exclusive)
		// LMS's fixed setting follows what is read: the follow player's saved Fixed turns it back on
		#expect(FixedVolumeSync.value(for: settings.player(PlayerKey.follow, device: speakers).volume) == 1)
	}

	/// inline review 2026-10-14, finding 1: the Settings window wrote Follow's choice as the device it
	/// followed then offered it. Following an output with no volume control (the FiiO as the macOS
	/// output), its own volume was saved as Software, and back on the speakers Follow had no -V.
	@Test func followKeepsItsVolumeChoiceWhateverItFollows() {
		let saved = Settings() // Follow: its own volume
		// what Save, a switch or a field behind the cog writes while Follow plays to the FiiO
		var written = saved
		written.players[PlayerKey.follow] = saved.forSaving(PlayerKey.follow, device: fiio)
		#expect(written.players[PlayerKey.follow]?.volume == .device)
		// back on the speakers: its own volume, the Mac's slider both ways
		#expect(written.player(PlayerKey.follow, device: speakers).volume == .device)
		#expect(args(written, speakers).contains("-V"))
		// while it follows the FiiO it still plays as the FiiO offers
		#expect(written.player(PlayerKey.follow, device: fiio).volume == .software)
		#expect(!args(written, fiio, key: PlayerKey.follow).contains("-V"))
		// no record yet (a switch flipped before any Save): the default, not the FiiO's choice
		var empty = Settings()
		empty.players = [:]
		#expect(empty.forSaving(PlayerKey.follow, device: fiio).volume == .device)
		// control: a device's own player is still written as its device offers (ONLY WHAT A DEVICE
		// OFFERS), with the rest of its settings
		var own = Settings()
		own.players[fiio.uid] = player(fiio, dop: true, volume: .device)
		#expect(own.forSaving(fiio.uid, device: fiio).volume == .software)
		#expect(own.forSaving(fiio.uid, device: fiio).dop)
		#expect(own.forSaving(fiio.uid, device: fiio) == own.player(fiio.uid, device: fiio))
	}

	@Test func sameInputsGiveTheSameArguments() {
		#expect(args(Settings(), fiio) == args(Settings(), fiio))
		#expect(args(Settings(), fiio) != args(Settings(), speakers))
	}

	/// each player is its own LMS player: its own MAC, name file and log
	@Test func eachPlayerHasItsOwnIdentity() {
		let a = EngineArguments.build(settings: Settings(), key: fiio.uid, device: fiio, mac: "02:00:00:00:00:01",
									  nameFile: "/a/name", logFile: "/a.log")
		#expect(value("-m", in: a) == "02:00:00:00:00:01")
		#expect(value("-N", in: a) == "/a/name")
		#expect(value("-f", in: a) == "/a.log")
	}
}

@Suite struct SettingsFile {
	@Test func missingKeysTakeDefaults() throws {
		let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"version":2,"server":"plex"}"#.utf8))
		#expect(settings.server == "plex")
		#expect(settings.idleSeconds == 30)
		#expect(settings.isOn(PlayerKey.follow))
	}

	@Test func roundTrip() throws {
		var settings = Settings()
		settings.players[fiio.uid] = player(fiio, dop: true, volume: .fixed)
		settings.players[dragonfly.uid] = player(dragonfly, volume: .fixed, held: 17)
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrionplay-settings-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: url) }
		try settings.save(to: url)
		#expect(Settings.load(from: url) == settings)
		#expect(Settings.read(from: url) == .current(settings))
	}

	/// Simon, 2026-10-12: "We dont need to carry existing settings from a previosu install we can start
	/// again no migration needed". A 0.3.x file is set aside, not read and not lost.
	@Test func aFileFromBeforePlayersIsSetAside() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrionplay-\(UUID())")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let url = dir.appendingPathComponent("settings.json")
		// 0.3.14's keys, as its file has them (Simon's settings-0.3.json, set aside by 0.4.0): server,
		// idleSeconds, resampleQuality and logLevel are this build's keys too, with the same types
		// (/code-review 2026-10-15, finding 4)
		let old = #"{"devices":{"x":{"dop":true,"exclusive":true,"rateSwitchDelayMs":0,"volume":"software"}},"idleSeconds":10,"logLevel":"info","outputDevice":"x","playerName":"Mac","resampleQuality":"v","server":""}"#
		try Data(old.utf8).write(to: url)
		#expect(Settings.read(from: url) == .older)
		#expect(Settings.load(from: url) == Settings())
		let aside = try Settings.setAsideOlder(at: url)
		#expect(aside?.lastPathComponent == "settings-0.3.json")
		#expect(try String(contentsOf: dir.appendingPathComponent("settings-0.3.json"), encoding: .utf8) == old)
		#expect(Settings.read(from: url) == .current(Settings()))
		// control: a current file is left where it is
		#expect(try Settings.setAsideOlder(at: url) == nil)
		#expect(Settings.read(from: dir.appendingPathComponent("missing.json")) == .missing)
	}

	/// Simon, 2026-10-14: settings carry over from 0.4.0 on. A file from an earlier 0.4.x lacks the
	/// keys a later build adds; each takes its default, and the file is not set aside
	@Test func anEarlierVersionTwoFileStillLoads() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrionplay-settings-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: url) }
		// only a name: every other key of a player missing, as a file before that key existed has it
		let earlier = #"{"version":2,"server":"plex","players":{"follow":{"name":"Study","enabled":true},"x":{"name":"DAC","enabled":true,"volume":"fixed","heldVolume":48}}}"#
		try Data(earlier.utf8).write(to: url)
		guard case .current(let settings) = Settings.read(from: url) else { Issue.record("not read: \(Settings.read(from: url))"); return }
		#expect(settings.server == "plex")
		#expect(settings.players["follow"] == PlayerSettings(enabled: true, name: "Study", exclusive: false, dop: false, volume: .device))
		#expect(settings.players["x"]?.volume == .fixed && settings.players["x"]?.heldVolume == 48)
		#expect(settings.players["x"]?.rateSwitchDelayMs == 0)
		#expect(try Settings.setAsideOlder(at: url) == nil)
		#expect(try String(contentsOf: url, encoding: .utf8) == earlier)
		// a key this build does not know (a later build's) is passed over, and a later version is read
		try Data(#"{"version":3,"later":1,"players":{"follow":{"name":"Study","later":true}}}"#.utf8).write(to: url)
		#expect(Settings.load(from: url).players["follow"]?.name == "Study")
	}

	/// /code-review 2026-10-14, finding 1: a file that does not decode was set aside as 0.3.x's, over
	/// any settings-0.3.json, and the defaults written in its place
	@Test func anUnreadableFileIsLeftAlone() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrionplay-\(UUID())")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let url = dir.appendingPathComponent("settings.json"), aside = dir.appendingPathComponent("settings-0.3.json")
		let bad = #"{"version":2,"players":{"follow":{"enabled":"yes","name":"Study"}}}"#
		try Data(bad.utf8).write(to: url)
		try Data("0.3".utf8).write(to: aside)
		guard case .unreadable = Settings.read(from: url) else { Issue.record("read as \(Settings.read(from: url))"); return }
		#expect(Settings.load(from: url) == Settings())
		#expect(try Settings.setAsideOlder(at: url) == nil)
		#expect(try String(contentsOf: url, encoding: .utf8) == bad)
		#expect(try String(contentsOf: aside, encoding: .utf8) == "0.3")
	}

	/// /code-review 2026-10-15, finding 2: a later build's file read here (a rollback) was saved back
	/// under the later version, with only this build's keys, so that build would skip its migration
	@Test func aLaterVersionIsSavedAsThisOne() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrionplay-settings-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: url) }
		try Data(#"{"version":3,"later":1,"server":"plex","players":{"follow":{"name":"Study","later":true}}}"#.utf8).write(to: url)
		let read = Settings.load(from: url)
		#expect(read.version == 3) // read as it is
		try read.save(to: url)
		let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
		#expect(saved?["version"] as? Int == Settings.currentVersion)
		#expect(saved?["later"] == nil) // this build cannot keep what it does not know: why the version is its own
		#expect(Settings.load(from: url).server == "plex")
		#expect(Settings.load(from: url).players["follow"]?.name == "Study")
	}

	/// SETTINGS CARRY OVER FROM 0.4.0 ON: only a file before players (0.3.x) is set aside, whatever
	/// `currentVersion` a later build raises it to. Compared with `currentVersion`, as it was, this fails
	/// in the build that raises it: every 0.4.x file would be set aside and reset
	@Test func everyFileFromVersionTwoOnIsRead() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrionplay-settings-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: url) }
		for version in 0...(Settings.currentVersion + 1) {
			try Data(#"{"version":\#(version),"players":{"follow":{"name":"Study"}}}"#.utf8).write(to: url)
			if version < 2 {
				#expect(Settings.read(from: url) == .older, "version \(version)")
			} else {
				guard case .current(let settings) = Settings.read(from: url) else {
					Issue.record("version \(version) read as \(Settings.read(from: url))"); continue
				}
				#expect(settings.players["follow"]?.name == "Study", "version \(version)")
			}
		}
	}

	@Test func followFollowsTheMacOSOutput() {
		#expect(Settings().followDevice(in: devices)?.uid == "BuiltInSpeakerDevice")
		#expect(Settings().followDevice(in: []) == nil)
	}
}

@Suite struct Identity {
	@Test func macIsLocallyAdministeredAndKept() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrionplay-mac-\(UUID())")
		defer { try? FileManager.default.removeItem(at: url) }
		let first = try PlayerIdentity.loadOrCreateMAC(at: url)
		#expect(PlayerIdentity.isValid(first))
		let firstByte = UInt8(first.prefix(2), radix: 16)!
		#expect(firstByte & 0x02 == 0x02) // locally administered
		#expect(firstByte & 0x01 == 0) // unicast
		#expect(try PlayerIdentity.loadOrCreateMAC(at: url) == first)
		#expect(!PlayerIdentity.isValid("02:00:4c:4d:50")) // control: a short address is refused
	}

	/// each player has its own folder and log, named so they can be read, and never shared
	@Test func eachPlayerHasItsOwnFiles() {
		#expect(Paths.slug(PlayerKey.follow) == "follow")
		let slug = Paths.slug(dragonfly.uid)
		#expect(slug.hasPrefix("AppleUSBAudioEngine-AudioQuest-AudioQuest-Dragon-")) // cut at 48
		#expect(slug.range(of: "^[A-Za-z0-9.-]+-[0-9a-f]{4}$", options: .regularExpression) != nil)
		#expect(Paths.slug(dragonfly.uid) == slug)                      // the same every time
		#expect(Paths.slug(fiio.uid) != slug)
		// two UIDs alike up to the cut, and alike once made file-safe, still differ
		#expect(Paths.slug(String(repeating: "a", count: 60) + "1") != Paths.slug(String(repeating: "a", count: 60) + "2"))
		#expect(Paths.slug("a:b") != Paths.slug("a b"))
		#expect(Paths.mac(dragonfly.uid).deletingLastPathComponent().path == Paths.players.appendingPathComponent(slug).path)
		#expect(Paths.engineLog(dragonfly.uid).lastPathComponent == "engine-\(slug).log")
	}

	/// 0.3.x's one player carries on as *Follow the macOS output* (Simon, 2026-10-12): its MAC and
	/// name are taken once, copied, and never over the player's own
	@Test func theOldPlayerCarriesOnAsFollow() throws {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent("lyrionplay-adopt-\(UUID())")
		defer { try? fm.removeItem(at: dir) }
		try fm.createDirectory(at: dir, withIntermediateDirectories: true)
		let oldMAC = dir.appendingPathComponent("mac"), oldName = dir.appendingPathComponent("player-name")
		let mac = dir.appendingPathComponent("players/follow/mac"), name = dir.appendingPathComponent("players/follow/name")
		try "96:57:54:14:bd:87\n".write(to: oldMAC, atomically: true, encoding: .utf8)
		try "Study".write(to: oldName, atomically: true, encoding: .utf8)

		#expect(try PlayerIdentity.adoptOldPlayer(mac: oldMAC, name: oldName, macAt: mac, nameAt: name) == "96:57:54:14:bd:87")
		#expect(try PlayerIdentity.loadOrCreateMAC(at: mac) == "96:57:54:14:bd:87")
		#expect(try String(contentsOf: name, encoding: .utf8) == "Study")
		#expect(fm.fileExists(atPath: oldMAC.path) && fm.fileExists(atPath: oldName.path)) // copied, not moved

		// once the player has its own, nothing is taken again: a rename LMS wrote stays
		try "Study 2".write(to: name, atomically: true, encoding: .utf8)
		try "02:11:22:33:44:55".write(to: oldMAC, atomically: true, encoding: .utf8)
		#expect(try PlayerIdentity.adoptOldPlayer(mac: oldMAC, name: oldName, macAt: mac, nameAt: name) == nil)
		#expect(try PlayerIdentity.loadOrCreateMAC(at: mac) == "96:57:54:14:bd:87")
		#expect(try String(contentsOf: name, encoding: .utf8) == "Study 2")
	}

	/// /code-review 2026-10-14, finding 2: a rename saved in Settings while the player (or LyrionPlay)
	/// was off never reached LMS; a rename made in LMS (squeezelite writes it to the file) must stay
	@Test func aRenameInSettingsReachesTheNameFile() throws {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent("lyrionplay-name-\(UUID())")
		defer { try? fm.removeItem(at: dir) }
		let name = dir.appendingPathComponent("players/x/name"), applied = dir.appendingPathComponent("players/x/settings-name")
		func file() throws -> String { try String(contentsOf: name, encoding: .utf8) }

		#expect(try PlayerIdentity.applyName("Mac DAC", at: name, applied: applied, saved: true) == false) // new: written
		#expect(try file() == "Mac DAC")
		#expect(try PlayerIdentity.applyName("Mac DAC", at: name, applied: applied, saved: true) == false) // control: no change
		// renamed in Settings, however long ago, whatever ran meanwhile
		#expect(try PlayerIdentity.applyName("Study DAC", at: name, applied: applied, saved: true) == true)
		#expect(try file() == "Study DAC")
		// renamed in LMS: squeezelite writes the file; the same Settings name leaves it
		try "Lounge".write(to: name, atomically: true, encoding: .utf8)
		#expect(try PlayerIdentity.applyName("Study DAC", at: name, applied: applied, saved: true) == false)
		#expect(try file() == "Lounge")
		// a player from before the record keeps its file, and a later rename in Settings lands
		try fm.removeItem(at: applied)
		#expect(try PlayerIdentity.applyName("Other", at: name, applied: applied, saved: true) == false)
		#expect(try file() == "Lounge")
		#expect(try PlayerIdentity.applyName("Desk", at: name, applied: applied, saved: true) == true)
		#expect(try file() == "Desk")
	}

	/// /code-review 2026-10-15, finding 1: with settings.json unreadable at its start, the agent runs the
	/// defaults, whose name (the Mac's) wrote over the name file and the record: a rename made in LMS
	/// was lost for good, and LMS showed the Mac's name
	@Test func theDefaultsNeverRenameAPlayer() throws {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent("lyrionplay-name-\(UUID())")
		defer { try? fm.removeItem(at: dir) }
		let name = dir.appendingPathComponent("players/follow/name"), applied = dir.appendingPathComponent("players/follow/settings-name")
		func file() throws -> String { try String(contentsOf: name, encoding: .utf8) }
		func record() -> String? { try? String(contentsOf: applied, encoding: .utf8) }

		// named Study in Settings, then Lounge in LMS
		try PlayerIdentity.applyName("Study", at: name, applied: applied, saved: true)
		try "Lounge".write(to: name, atomically: true, encoding: .utf8)
		// the file unreadable at the agent's start: the defaults' name touches nothing
		#expect(try PlayerIdentity.applyName("Mac", at: name, applied: applied, saved: false) == false)
		#expect(try file() == "Lounge")
		#expect(record() == "Study")
		// the file read again: Settings' name is the one it put there, so LMS's rename stays
		#expect(try PlayerIdentity.applyName("Study", at: name, applied: applied, saved: true) == false)
		#expect(try file() == "Lounge")
		// control: the same name from settings.json is a rename in Settings, and lands
		#expect(try PlayerIdentity.applyName("Mac", at: name, applied: applied, saved: true) == true)
		#expect(try file() == "Mac")

		// a player from before the record: the defaults write no record, so a later read keeps the file
		try fm.removeItem(at: applied)
		try "Lounge".write(to: name, atomically: true, encoding: .utf8)
		#expect(try PlayerIdentity.applyName("Mac", at: name, applied: applied, saved: false) == false)
		#expect(record() == nil)
		#expect(try PlayerIdentity.applyName("Study", at: name, applied: applied, saved: true) == false)
		#expect(try file() == "Lounge")

		// no name file at all: the defaults make one, recorded as theirs, so Settings' name replaces it
		try fm.removeItem(at: name)
		try fm.removeItem(at: applied)
		#expect(try PlayerIdentity.applyName("Mac", at: name, applied: applied, saved: false) == false)
		#expect(try file() == "Mac")
		#expect(try PlayerIdentity.applyName("Study", at: name, applied: applied, saved: true) == true)
		#expect(try file() == "Study")
	}

	/// with no usable 0.3.x MAC, the follow player is new, and takes no old name either
	@Test func noOldPlayerMeansANewOne() throws {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent("lyrionplay-adopt-\(UUID())")
		defer { try? fm.removeItem(at: dir) }
		try fm.createDirectory(at: dir, withIntermediateDirectories: true)
		let oldMAC = dir.appendingPathComponent("mac"), oldName = dir.appendingPathComponent("player-name")
		let mac = dir.appendingPathComponent("players/follow/mac"), name = dir.appendingPathComponent("players/follow/name")
		try "Study".write(to: oldName, atomically: true, encoding: .utf8)

		#expect(try PlayerIdentity.adoptOldPlayer(mac: oldMAC, name: oldName, macAt: mac, nameAt: name) == nil)
		try "not a mac".write(to: oldMAC, atomically: true, encoding: .utf8)
		#expect(try PlayerIdentity.adoptOldPlayer(mac: oldMAC, name: oldName, macAt: mac, nameAt: name) == nil)
		#expect(!fm.fileExists(atPath: mac.path) && !fm.fileExists(atPath: name.path))
		#expect(PlayerIdentity.isValid(try PlayerIdentity.loadOrCreateMAC(at: mac)))
	}
}

/// Simon, 2026-10-12: Settings lists *Follow the macOS output*, then every device squeezelite lists
/// except the Mac's built-in speakers/headphones; HDMI, Bluetooth and AirPlay included
@Suite struct PlayerRows {
	var all: [DeviceCaps] { devices + [dragonfly, hdmi] }

	@Test func followFirstThenEveryDeviceButTheBuiltInOnes() {
		let rows = PlayerList.rows(settings: Settings(), devices: all)
		#expect(rows.map(\.key) == [PlayerKey.follow, fiio.uid, dragonfly.uid, hdmi.uid])
		#expect(rows.first?.device?.uid == speakers.uid)              // what it follows now
		#expect(!rows.contains { $0.key == speakers.uid })
	}

	/// a device with saved settings that is not plugged in keeps its row, its switch and its cog
	@Test func aDeviceNotConnectedKeepsItsRow() {
		var settings = Settings()
		settings.players[dragonfly.uid] = player(dragonfly, volume: .fixed, held: 17)
		let rows = PlayerList.rows(settings: settings, devices: devices)
		#expect(rows.map(\.key) == [PlayerKey.follow, fiio.uid, dragonfly.uid])
		#expect(rows.last?.device == nil)
	}

	/// only the follow player is on to begin with; it is named after the Mac, a device's player after
	/// the Mac then the device
	@Test func defaults() {
		let settings = Settings()
		#expect(settings.isOn(PlayerKey.follow))
		#expect(!settings.isOn(dragonfly.uid))
		#expect(settings.player(PlayerKey.follow, device: speakers).name == PlayerSettings.macName)
		#expect(settings.player(dragonfly.uid, device: dragonfly).name
				== "\(PlayerSettings.macName) AudioQuest DragonFly Black v1.5")
		#expect(settings.player(dragonfly.uid, device: dragonfly).exclusive)   // an external DAC
		#expect(!settings.player(PlayerKey.follow, device: speakers).exclusive)
	}
}

/// the agent runs one engine per player that is on and connected, and changes only what changed
@Suite struct EnginePlanning {
	func plan(_ settings: Settings, _ list: [DeviceCaps]) -> [String: EngineSpec] {
		EnginePlan.make(settings: settings, devices: list, followDevice: settings.followDevice(in: list)) {
			args(settings, $1, key: $0)
		}
	}

	@Test func oneEnginePerPlayerThatIsOnAndConnected() {
		var settings = Settings()
		#expect(Set(plan(settings, devices + [dragonfly]).keys) == [PlayerKey.follow])
		settings.players[dragonfly.uid] = player(dragonfly, volume: .device)
		let both = plan(settings, devices + [dragonfly])
		#expect(Set(both.keys) == [PlayerKey.follow, dragonfly.uid])
		#expect(both[dragonfly.uid]?.device.uid == dragonfly.uid && both[PlayerKey.follow]?.device.uid == speakers.uid)
		#expect(Set(plan(settings, devices).keys) == [PlayerKey.follow])     // the DragonFly unplugged
		settings.players[PlayerKey.follow]?.enabled = false
		#expect(Set(plan(settings, devices + [dragonfly]).keys) == [dragonfly.uid])
	}

	@Test func onlyWhatChangedIsStoppedAndStarted() {
		var settings = Settings()
		settings.players[dragonfly.uid] = player(dragonfly, volume: .device)
		let before = plan(settings, devices + [dragonfly])
		let running = before.mapValues(\.args)
		#expect(EnginePlan.changes(running: running, wanted: before) == ([], []))
		settings.players[dragonfly.uid]?.volume = .fixed                  // one player's setting
		settings.players[dragonfly.uid]?.heldVolume = 17
		let after = plan(settings, devices + [dragonfly])
		#expect(EnginePlan.changes(running: running, wanted: after) == ([dragonfly.uid], [dragonfly.uid]))
		settings.players[dragonfly.uid]?.enabled = false                  // switched off
		#expect(EnginePlan.changes(running: running, wanted: plan(settings, devices + [dragonfly])) == ([dragonfly.uid], []))
		#expect(EnginePlan.changes(running: [:], wanted: before) == ([], [PlayerKey.follow, dragonfly.uid].sorted()))
	}
}

/// FIXED HOLDS THE LMS VOLUME: the level is the volume LMS has saved for the player
@Suite struct HeldVolumes {
	@Test func theSavedVolumeIsHeld() {
		#expect(HeldVolume.from(lmsVolume: 17) == .held(17))
		#expect(HeldVolume.from(lmsVolume: -17) == .held(17))           // muted: its level, kept negative by LMS
		#expect(HeldVolume.from(lmsVolume: 37.5) == .held(38))
	}

	/// /code-review 2026-10-14, finding 4: Fixed holds the device where *Device's own volume* had it
	/// for the same LMS volume, LMS's rounded gain, not the curve before LMS rounds it
	@Test func fixedHoldsWhereTheDevicesOwnVolumeHadIt() {
		#expect(String(format: "%.2f", HeldVolume.dB(17)) == "-48.83")     // the DragonFly reported LMS 17 at -48.83
		#expect(String(format: "%.2f", HeldVolume.dB(48)) == "-25.89")     // and read LMS 48 at -25.89 (0.4.2)
		#expect(String(format: "%.2f", HeldVolume.dB(40)) == "-30.10")     // the largest gap: 0.50 dB
		#expect(HeldVolume.dB(100) == 0)
		// control: the curve LMS rounds is not where the device goes (Fixed held -25.65 at 48 on 0.4.0)
		#expect(abs(LMSVolume.dB(48) - HeldVolume.dB(48)) > 0.2)
	}

	/// LMS's gains, as the engine suite pins them (lms_gain, LMS_VOL33...LMS_VOL42), so the agent and
	/// the engine agree on every level
	@Test func lmsGainsMatchTheEngine() {
		#expect(LMSVolume.gain(33) == 1458 && LMSVolume.gain(40) == 2048)
		#expect(LMSVolume.gain(41) == 2304 && LMSVolume.gain(42) == 2304)   // LMS's own 8-bit rounding
		#expect(LMSVolume.gain(48) == 3328 && LMSVolume.gain(17) == 237)
		#expect(LMSVolume.gain(100) == 65536 && LMSVolume.gain(0) == 0)
	}

	@Test func nothingToHoldIsRefused() {
		guard case .refused = HeldVolume.from(lmsVolume: nil) else { Issue.record("no answer was held"); return }
		guard case .refused = HeldVolume.from(lmsVolume: 0) else { Issue.record("0 was held"); return }
		guard case .refused = HeldVolume.from(lmsVolume: -0.2) else { Issue.record("a muted 0 was held"); return }
	}
}

/// The agent reopens the menu only when no menu holds the lock, so the lock must be released
/// however the menu app ends, and only then.
@Suite(.serialized) struct MenuLock {
	let lock = FileManager.default.temporaryDirectory
		.appendingPathComponent("lyrionplay-menu-\(UUID().uuidString).lock")

	@Test func heldWhileClaimedFreeAfter() {
		#expect(!MenuPresence.isRunning(lock: lock)) // control: nobody holds it yet
		#expect(MenuPresence.claim(waiting: 0, lock: lock))
		#expect(MenuPresence.isRunning(lock: lock))
		#expect(MenuPresence.isRunning(lock: lock)) // the check itself must not take the lock away
		#expect(!MenuPresence.claim(waiting: 0.3, lock: lock)) // a second menu is refused
		MenuPresence.release()
		#expect(!MenuPresence.isRunning(lock: lock))
	}

	/// a crashed or force-quit menu: the kernel drops a SIGKILLed holder's lock
	@Test func releasedWhenTheHolderIsKilled() throws {
		let holder = Process()
		holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
		holder.arguments = ["-e", "use Fcntl ':flock'; $| = 1; open F, '>>', $ARGV[0] or die; flock F, LOCK_EX or die; print \"held\\n\"; sleep 30", lock.path]
		let out = Pipe()
		holder.standardOutput = out
		try holder.run()
		_ = out.fileHandleForReading.availableData // returns once the holder prints "held"
		#expect(MenuPresence.isRunning(lock: lock))
		kill(holder.processIdentifier, SIGKILL)
		holder.waitUntilExit()
		#expect(!MenuPresence.isRunning(lock: lock))
	}
}

/// Mac volume -> LMS slider: the inverse must land on the position LMS itself would send.
@Suite struct VolumeCurve {
	@Test func matchesLMSFormula() {
		// Squeezebox2::getVolume with SqueezePlay's parameters, worked by hand
		#expect(LMSVolume.dB(100) == 0)
		#expect(abs(LMSVolume.dB(25) - -37) < 1e-9)          // the knee
		#expect(abs(LMSVolume.dB(60) - -19.7333) < 1e-3)     // 37/75 * -40
		#expect(abs(LMSVolume.dB(10) - -59.2) < 1e-9)        // 1.48 * 10 - 74
		#expect(abs(LMSVolume.dB(1) - -72.52) < 1e-9)
		// control: Squeezebox2's own curve (-50 dB over 100 steps) would put 60 at -20 dB
		#expect(abs(LMSVolume.dB(60) - -20) > 0.2)
	}

	@Test func roundTripsEveryPosition() {
		for v in 1...100 { #expect(LMSVolume.volume(forDB: LMSVolume.dB(v)) == v) }
	}

	@Test func deviceLevels() {
		#expect(LMSVolume.volume(forDB: 0) == 100)
		#expect(LMSVolume.volume(forDB: 6) == 100)            // above the top stays at the top
		#expect(LMSVolume.volume(forDB: -63.5) == 7)          // MacBook Pro speakers' minimum
		#expect(LMSVolume.volume(forDB: -120) == 1)           // never 0: a level is not a mute
		#expect(LMSVolume.volume(forDB: -19.5) == 60)         // a 0.5 dB device step still lands on 60
	}

	/// The engine predicts LMS's answer to each report from the whole volume the agent asks for, and
	/// does not put that answer on the device (output_coreaudio.c `agent_volume`). These rows are the
	/// engine suite's `the engine knows LMS's answer to each report`, read here as the engine prints
	/// them: change both or neither.
	@Test func theAgentsWholeVolumeIsTheEnginesToo() {
		let rows: [(String, Int)] = [
			("-74.00", 1), ("-100.00", 1), ("-63.50", 7), ("-50.00", 16), ("-37.00", 25), ("-36.75", 26),
			("-33.05", 33), ("-30.00", 39), ("-29.60", 40), ("-29.40", 40), ("-29.35", 41), ("-29.11", 41),
			("-28.61", 42), ("-20.00", 59), ("-0.20", 100), ("0.00", 100), ("5.00", 100),
		]
		for (printed, volume) in rows {
			let report = VolumeReport(line: "lyrionplay:volume \(printed) 0 1")
			#expect(report.map { LMSVolume.volume(forDB: $0.dB) } == volume, "\(printed) dB")
		}
	}
}

// MARK: - review 2026-10-10 regressions

/// Finding 1: macOS moves its default output away from a device another process holds exclusively,
/// and back when it is let go (measured 2026-10-10, under 10 ms each way). "Follow the macOS
/// output" must not chase that, or the player restarts on the speakers mid-track.
@Suite struct FollowSystem {
	/// what the probe shows while the engine holds the FiiO: macOS has made the speakers the default
	var whileHeld: [DeviceCaps] {
		var list = devices
		for i in list.indices { list[i].isDefault = list[i].uid == speakers.uid }
		return list
	}

	@Test func staysOnTheDeviceItHolds() {
		let settings = Settings() // follows the macOS output
		#expect(settings.followDevice(in: whileHeld, holding: fiio.uid)?.uid == fiio.uid)
		// control: without the hold the macOS default wins, which is what moved the player before
		#expect(settings.followDevice(in: whileHeld)?.uid == speakers.uid)
	}

	@Test func aHeldDeviceThatIsGoneIsNotKept() {
		let settings = Settings()
		let withoutFiiO = whileHeld.filter { $0.uid != fiio.uid }
		#expect(settings.followDevice(in: withoutFiiO, holding: fiio.uid)?.uid == speakers.uid)
	}
}

/// Simon, 2026-10-10: when the macOS output is a device with its own player on, *Follow the macOS
/// output* plays to the Mac's built-in output; two engines never play to one device
@Suite struct FollowAndOwnPlayers {
	var fiioDefault: [DeviceCaps] {
		var list = devices
		for i in list.indices { list[i].isDefault = list[i].uid == fiio.uid }
		return list
	}

	@Test func aDeviceWithItsOwnPlayerOnIsNotFollowed() {
		var settings = Settings()
		#expect(settings.followDevice(in: fiioDefault)?.uid == fiio.uid) // control: its player is off
		settings.players[fiio.uid] = player(fiio, volume: .software)
		#expect(settings.followDevice(in: fiioDefault)?.uid == speakers.uid)
		// held by the follow player when its own player is switched on: not kept either
		#expect(settings.followDevice(in: fiioDefault, holding: fiio.uid)?.uid == speakers.uid)
		// its player off again: followed
		settings.players[fiio.uid]?.enabled = false
		#expect(settings.followDevice(in: fiioDefault)?.uid == fiio.uid)
	}

	@Test func noBuiltInOutputMeansNoDevice() {
		var settings = Settings()
		settings.players[fiio.uid] = player(fiio, volume: .software)
		#expect(settings.followDevice(in: fiioDefault.filter { !$0.isBuiltIn }) == nil)
	}
}

/// Findings 5 and 6: the engine's report line, and what the agent asks LMS for it.
@Suite struct VolumeReports {
	@Test func parsesTheEngineLine() {
		#expect(VolumeReport(line: "lyrionplay:volume -28.72 0 1") == VolumeReport(dB: -28.72, muted: false, lms: .audible))
		#expect(VolumeReport(line: "lyrionplay:volume -63.50 1 0") == VolumeReport(dB: -63.5, muted: true, lms: .silent))
		#expect(VolumeReport(line: "lyrionplay:volume -30.00 0 -1")?.lms == .unknown)
		// <moved>: 0 only the mute changed, 1 the level moved; a line without it moved
		#expect(VolumeReport(line: "lyrionplay:volume -63.50 0 0 0") == VolumeReport(dB: -63.5, muted: false, lms: .silent, levelMoved: false))
		#expect(VolumeReport(line: "lyrionplay:volume -30.00 0 0 1")?.levelMoved == true)
		#expect(VolumeReport(line: "lyrionplay:volume -30.00 0 1")?.levelMoved == true)
		#expect(VolumeReport(line: "lyrionplay:volume -30.00 0 0 2") == nil)
		#expect(VolumeReport(line: "lyrionplay:volume -30.00 0 0 1 9") == nil)
		// a line without <lms> asks LMS everything, as before
		#expect(VolumeReport(line: "lyrionplay:volume -30.00 0")?.lms == .unknown)
	}

	@Test func otherLinesAreNotReports() {
		#expect(VolumeReport(line: "lyrionplay:volume") == nil)
		#expect(VolumeReport(line: "lyrionplay:volume loud 0 1") == nil)
		#expect(VolumeReport(line: "lyrionplay:volume -30 2 1") == nil)
		#expect(VolumeReport(line: "[10:00:00.000] output_init_coreaudio:1111 init output") == nil)
	}
}

/// The menu showed 176.4 kHz for DSD64: the engine says what plays, and the menu shows the DSD rate.
@Suite struct FormatReports {
	@Test func parsesTheEngineLine() {
		#expect(FormatReport(line: "lyrionplay:format 176400 dop") == FormatReport(rate: 176400, dop: true))
		#expect(FormatReport(line: "lyrionplay:format 44100 pcm") == FormatReport(rate: 44100, dop: false))
	}

	@Test func otherLinesAreNotReports() {
		#expect(FormatReport(line: "lyrionplay:format") == nil)
		#expect(FormatReport(line: "lyrionplay:format 176400") == nil)
		#expect(FormatReport(line: "lyrionplay:format 0 dop") == nil)
		#expect(FormatReport(line: "lyrionplay:format 176400 dsd") == nil)
		#expect(FormatReport(line: "lyrionplay:volume -30.00 0 1") == nil)
		#expect(VolumeReport(line: "lyrionplay:format 176400 dop") == nil)
	}

	@Test func dopAtTheDevicesRateIsDSD() {
		#expect(FormatReport(rate: 176400, dop: true).dsdRate(deviceRate: 176400) == 2_822_400)
		#expect(FormatReport(rate: 352800, dop: true).dsdRate(deviceRate: 352800) == 5_644_800)
		// a DAC offering 705.6k / 1411.2k takes DSD256 / DSD512 as DoP (dsd.c: rate / 16 <= its top rate)
		#expect(FormatReport(rate: 705600, dop: true).dsdRate(deviceRate: 705600) == 11_289_600)
		#expect(FormatReport(rate: 1_411_200, dop: true).dsdRate(deviceRate: 1_411_200) == 22_579_200)
		// DSD256 on the FiiO is converted to 352.8k PCM (DSD256 IS PCM ON THE FIIO): a kHz rate
		#expect(FormatReport(rate: 352800, dop: false).dsdRate(deviceRate: 352800) == nil)
	}

	@Test func aDeviceThatMovedIsNotRelabelled() {
		// released after DSD64, then another app set 48k: the old report says nothing of that
		#expect(FormatReport(rate: 176400, dop: true).dsdRate(deviceRate: 48000) == nil)
		#expect(FormatReport(rate: 176400, dop: true).dsdRate(deviceRate: nil) == nil)
	}

	/// /code-review 2026-10-12, finding 3: a DAC keeps DoP's rate after the idle release, so only the
	/// engine's release line can drop the report (the device-rate rule cannot see it)
	@Test func theReleaseDropsTheReport() {
		#expect(FormatLine(line: "lyrionplay:format idle") == .idle)
		#expect(FormatLine(line: "lyrionplay:format idle")?.report == nil)
		#expect(FormatLine(line: "lyrionplay:format 176400 dop")?.report == FormatReport(rate: 176400, dop: true))
		#expect(FormatReport(line: "lyrionplay:format idle") == nil)
		#expect(FormatLine(line: "lyrionplay:format idle now") == nil)
		#expect(FormatLine(line: "lyrionplay:volume -30.00 0 1") == nil)
		#expect(VolumeReport(line: "lyrionplay:format idle") == nil)
		// control: the rate rule alone keeps DSD64 on the released DAC, still at 176.4k
		#expect(FormatReport(rate: 176400, dop: true).dsdRate(deviceRate: 176400) == 2_822_400)
	}

	/// every DSD rate, both families, as given (Simon, 2026-10-12): another user's DAC may take any
	/// of them as DoP (DSD512 at 1411.2k, a 48 kHz-family DAC at 192k for DSD64)
	@Test func dsdLabels() {
		#expect(DeviceCaps.dsd(2_822_400) == "DSD64 (2.8224 MHz)")
		#expect(DeviceCaps.dsd(5_644_800) == "DSD128 (5.6448 MHz)")
		#expect(DeviceCaps.dsd(11_289_600) == "DSD256 (11.2896 MHz)")
		#expect(DeviceCaps.dsd(22_579_200) == "DSD512 (22.5792 MHz)")
		#expect(DeviceCaps.dsd(45_158_400) == "DSD1024 (45.1584 MHz)")
		#expect(DeviceCaps.dsd(3_072_000) == "DSD64 (3.0720 MHz)")
		#expect(DeviceCaps.dsd(6_144_000) == "DSD128 (6.1440 MHz)")
		#expect(DeviceCaps.dsd(12_288_000) == "DSD256 (12.2880 MHz)")
		#expect(DeviceCaps.dsd(24_576_000) == "DSD512 (24.5760 MHz)")
		#expect(DeviceCaps.dsd(49_152_000) == "DSD1024 (49.1520 MHz)")
	}

	/// one entry per player, each with its own device and format
	@Test func aStatusRoundTripsWithItsPlayers() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: url) }
		var status = AgentStatus(agentPID: 1)
		status.serverHost = "plex"
		status.serverWebPort = 9000
		var dac = PlayerStatus(key: dragonfly.uid, name: "DragonFly", mac: "02:00:00:00:00:02")
		dac.currentRate = 176400
		dac.dsdRate = 2_822_400
		status.players = [PlayerStatus(key: PlayerKey.follow, name: "Mac", mac: "02:00:00:00:00:01"), dac]
		status.updated = Date(timeIntervalSince1970: 1_800_000_000) // whole seconds: ISO 8601 keeps no fraction
		try status.save(to: url)
		let loaded = try #require(AgentStatus.load(from: url))
		#expect(loaded == status)
		#expect(loaded.player(dragonfly.uid)?.dsdRate == 2_822_400)
	}

	/// a status a 0.3.x agent wrote (one player, no list) loads with no players
	@Test func aStatusFromBeforePlayersLoadsWithNone() throws {
		let old = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: old) }
		try Data("""
			{"updated":"2026-10-11T20:00:00Z","agentPID":1,"engineRunning":true,"exclusive":true,"connected":true,
			 "currentRate":176400,"devices":[]}
			""".utf8).write(to: old)
		let status = try #require(AgentStatus.load(from: old))
		#expect(status.players.isEmpty)
	}
}

/// counts the questions the push asks LMS
final class FakeLMS: @unchecked Sendable {
	var fixed: Bool?
	var volume: Double?
	var fixedAsked = 0
	var volumeAsked = 0
	init(fixed: Bool?, volume: Double?) {
		self.fixed = fixed
		self.volume = volume
	}

	func command(_ report: VolumeReport) async -> [String]? {
		await VolumePush.command(for: report,
								 volumeFixed: { self.fixedAsked += 1; return self.fixed },
								 lmsVolume: { self.volumeAsked += 1; return self.volume })
	}
}

@Suite struct VolumePushDecision {
	@Test func aLevelWhileLMSHasALevelAsksNothing() async {
		let lms = FakeLMS(fixed: false, volume: 42)
		#expect(await lms.command(VolumeReport(dB: -28.72, muted: false, lms: .audible)) == ["mixer", "volume", "42"])
		#expect(lms.volumeAsked == 0) // was one `mixer volume ?` round trip per push
		#expect(lms.fixedAsked == 0)
	}

	@Test func unmuteWhileLMSIsMutedAsksLMSToUnmute() async {
		let lms = FakeLMS(fixed: false, volume: -42)
		#expect(await lms.command(VolumeReport(dB: -63.5, muted: false, lms: .silent, levelMoved: false)) == ["mixer", "muting", "0"])
		#expect(lms.volumeAsked == 1)
		// control: LMS at volume 0, not muted, gets the level
		let atZero = FakeLMS(fixed: false, volume: 0)
		#expect(await atZero.command(VolumeReport(dB: -28.72, muted: false, lms: .silent, levelMoved: false)) == ["mixer", "volume", "42"])
	}

	/// Simon, 2026-10-14: moving the Mac's volume while LMS is muted "should unmute LMS and move it
	/// the correct position"; it unmuted LMS to the volume it kept instead
	@Test func aLevelMovedWhileLMSIsMutedSetsThatLevel() async {
		let lms = FakeLMS(fixed: false, volume: -42)
		#expect(await lms.command(VolumeReport(dB: -28.72, muted: false, lms: .silent, levelMoved: true)) == ["mixer", "volume", "42"])
		#expect(lms.volumeAsked == 0)                       // no question needed
		// from the line as the engine prints it
		let line = VolumeReport(line: "lyrionplay:volume -33.05 0 0 1")
		#expect(await lms.command(line!) == ["mixer", "volume", "33"])
	}

	@Test func muteAsksNothing() async {
		let lms = FakeLMS(fixed: false, volume: 42)
		#expect(await lms.command(VolumeReport(dB: -28.72, muted: true, lms: .audible)) == ["mixer", "muting", "1"])
		#expect(lms.volumeAsked == 0)
	}

	/// finding 6: before any audg the engine cannot know LMS's volume is fixed
	@Test func beforeAnyAudgAFixedPlayerGetsNothing() async {
		let fixed = FakeLMS(fixed: true, volume: 42)
		#expect(await fixed.command(VolumeReport(dB: -28.72, muted: false, lms: .unknown)) == nil)
		#expect(await fixed.command(VolumeReport(dB: -28.72, muted: true, lms: .unknown)) == nil)
		#expect(fixed.fixedAsked == 2)
		// control: a player LMS controls gets the level; unknown asks whether it is fixed, and a level
		// that moved needs no volume question (it is sent even to a muted LMS, which it unmutes)
		let free = FakeLMS(fixed: false, volume: 42)
		#expect(await free.command(VolumeReport(dB: -28.72, muted: false, lms: .unknown)) == ["mixer", "volume", "42"])
		#expect(free.fixedAsked == 1 && free.volumeAsked == 0)
		// an unmute alone asks both
		let unmuted = FakeLMS(fixed: false, volume: 42)
		#expect(await unmuted.command(VolumeReport(dB: -28.72, muted: false, lms: .unknown, levelMoved: false)) == ["mixer", "volume", "42"])
		#expect(unmuted.fixedAsked == 1 && unmuted.volumeAsked == 1)
		// LMS not answering does not block the push
		let silent = FakeLMS(fixed: nil, volume: nil)
		#expect(await silent.command(VolumeReport(dB: -28.72, muted: false, lms: .unknown)) == ["mixer", "volume", "42"])
	}
}

/// "Fixed at 100%" per DAC (Simon, 2026-10-11): LMS's digitalVolumeControl follows the setting of
/// the device the engine plays to, both ways, and LyrionPlay owns it.
@Suite struct FixedAtFullPerDAC {
	let fixed = ["playerpref", "digitalVolumeControl", "0"]
	let control = ["playerpref", "digitalVolumeControl", "1"]

	@Test func aFixedDACSetsLMSFixedOnce() {
		var sync = FixedVolumeSync()
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 1) == fixed)
		let refused = sync.recordRefusal(device: fiio.uid, mode: .fixed, lmsAfter: 0)
		#expect(!refused)
		// LMS took it: the next check sends nothing
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 0) == nil)
	}

	/// the other modes turn LMS's volume control back on, so leaving a fixed DAC lands right
	@Test func anotherDACTurnsVolumeControlBackOn() {
		var sync = FixedVolumeSync()
		#expect(sync.checked(device: speakers.uid, mode: .device, lms: 0) == control)
		#expect(sync.checked(device: fiio.uid, mode: .software, lms: 0) == control)
		// control: already on, nothing to send
		#expect(sync.checked(device: speakers.uid, mode: .device, lms: 1) == nil)
		#expect(sync.checked(device: fiio.uid, mode: .software, lms: 1) == nil)
	}

	/// LyrionPlay owns the pref: a change made in LMS or Material is put back at the next check
	@Test func aChangeInLMSIsPutBack() {
		var sync = FixedVolumeSync()
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 1) == fixed)
		let refused = sync.recordRefusal(device: fiio.uid, mode: .fixed, lmsAfter: 0)
		#expect(!refused)
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 0) == nil)
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 1) == fixed) // turned back on in Material
	}

	/// a value LMS will not keep is said once, and not sent at every check after
	@Test func aRefusalIsNotALoop() {
		var sync = FixedVolumeSync()
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 1) == fixed)
		let refused = sync.recordRefusal(device: fiio.uid, mode: .fixed, lmsAfter: 1)
		#expect(refused)
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 1) == nil)
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 1) == nil)
		// another device, or another mode, is tried
		#expect(sync.checked(device: speakers.uid, mode: .fixed, lms: 1) == fixed)
		// LMS later at the wanted value (set by hand) clears the refusal
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 0) == nil)
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 1) == fixed)
	}

	/// no answer to the read after a send is not a refusal: the next check tries again
	@Test func noReadBackIsNotARefusal() {
		var sync = FixedVolumeSync()
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 1) == fixed)
		let refused = sync.recordRefusal(device: fiio.uid, mode: .fixed, lmsAfter: nil)
		#expect(!refused)
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: 1) == fixed)
	}

	/// LMS's change hook saves a faded (temporary) volume as the real one: 50 became 0 on the rig,
	/// 2026-10-11. It is put back.
	@Test func aFadedVolumeLMSSavedIsPutBack() {
		#expect(FixedVolumeSync.volumeRestore(before: 50, after: 0) == ["mixer", "volume", "50"])
		// mid-fade, LMS's temporary volume is a fraction
		#expect(FixedVolumeSync.volumeRestore(before: 50, after: 23.4567) == ["mixer", "volume", "50"])
		#expect(FixedVolumeSync.volumeRestore(before: 37.5, after: 0) == ["mixer", "volume", "37.5"])
		// control: the hook left it alone, or LMS did not answer
		#expect(FixedVolumeSync.volumeRestore(before: 50, after: 50) == nil)
		#expect(FixedVolumeSync.volumeRestore(before: nil, after: 0) == nil)
		#expect(FixedVolumeSync.volumeRestore(before: 50, after: nil) == nil)
	}

	/// a muted player's volume is negative, and `mixer volume -42` would turn it DOWN by 42
	@Test func aMutedVolumeIsNeverPutBack() {
		#expect(FixedVolumeSync.volumeRestore(before: -42, after: 0) == nil)
		// control: 0 is a level, not muted
		#expect(FixedVolumeSync.volumeRestore(before: 0, after: 12) == ["mixer", "volume", "0"])
	}

	@Test func lmsNotSayingSendsNothing() {
		var sync = FixedVolumeSync()
		#expect(sync.checked(device: fiio.uid, mode: .fixed, lms: nil) == nil)
	}

	/// status as LMS 9.1 gives it on the rig (an integer), and a string to be safe
	@Test func statusCarriesThePref() {
		#expect(LMSClient.PlayerState.digitalVolumeControl(in: ["digital_volume_control": 1, "mode": "stop"]) == 1)
		#expect(LMSClient.PlayerState.digitalVolumeControl(in: ["digital_volume_control": "0"]) == 0)
		#expect(LMSClient.PlayerState.digitalVolumeControl(in: ["mode": "stop"]) == nil)
	}

	@Test func aSettingsFileWithFixedLoads() throws {
		let json = #"{"version":2,"players":{"x":{"enabled":true,"name":"X","exclusive":true,"dop":false,"volume":"fixed","heldVolume":17,"rateSwitchDelayMs":0}}}"#
		let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
		#expect(settings.players["x"]?.volume == .fixed)
		#expect(settings.players["x"]?.heldVolume == 17)
	}
}

/// Finding 4: each push was its own task, two HTTP calls long, so pushes 150 ms apart could
/// overlap and reach LMS out of order, the older level sticking.
@Suite struct PushOrdering {
	final class Recorder: @unchecked Sendable {
		let lock = NSLock()
		var sends: [(value: Int, start: Date, end: Date)] = []
		var inFlight = 0
		var maxInFlight = 0
	}

	@Test func oneAtATimeInOrderAndTheLatestWins() async throws {
		let recorder = Recorder()
		let sender = LatestValueSender<Int>(interval: 0.03) { value in
			let start = Date()
			recorder.lock.withLock {
				recorder.inFlight += 1
				recorder.maxInFlight = max(recorder.maxInFlight, recorder.inFlight)
			}
			try? await Task.sleep(nanoseconds: 80_000_000) // a slow LMS: longer than the interval
			recorder.lock.withLock {
				recorder.inFlight -= 1
				recorder.sends.append((value, start, Date()))
			}
		}
		for value in 1...20 { // a volume key held: a report every 10 ms
			sender.submit(value)
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		let deadline = Date().addingTimeInterval(5)
		while recorder.lock.withLock({ recorder.sends.last?.value }) != 20, Date() < deadline {
			try await Task.sleep(nanoseconds: 20_000_000)
		}
		let sends = recorder.lock.withLock { recorder.sends }
		#expect(sends.last?.value == 20)                                  // the final level is the one LMS keeps
		#expect(recorder.maxInFlight == 1)                                 // never two at once
		#expect(zip(sends, sends.dropFirst()).allSatisfy { $0.value < $1.value })
		#expect(zip(sends, sends.dropFirst()).allSatisfy { $1.start >= $0.end })
		#expect(zip(sends, sends.dropFirst()).allSatisfy { $1.start.timeIntervalSince($0.start) >= 0.029 })
		#expect(sends.count < 20)                                          // control: reports were coalesced
	}

	/// control: the agent's old pattern, a detached task per push started at most every 150 ms,
	/// does overlap against the same slow LMS, so the test above can see what it rules out
	@Test func theOldPatternOverlaps() async throws {
		let recorder = Recorder()
		for value in 1...4 {
			Task.detached {
				recorder.lock.withLock {
					recorder.inFlight += 1
					recorder.maxInFlight = max(recorder.maxInFlight, recorder.inFlight)
				}
				try? await Task.sleep(nanoseconds: 400_000_000) // two round trips to a busy LMS
				recorder.lock.withLock {
					recorder.inFlight -= 1
					recorder.sends.append((value, Date(), Date()))
				}
			}
			try await Task.sleep(nanoseconds: 150_000_000)
		}
		try await Task.sleep(nanoseconds: 500_000_000)
		#expect(recorder.maxInFlight > 1)
	}

	@Test func aSingleValueIsSentOnce() async throws {
		let recorder = Recorder()
		let sender = LatestValueSender<Int>(interval: 0.15) { value in
			recorder.lock.withLock { recorder.sends.append((value, Date(), Date())) }
		}
		sender.submit(7)
		try await Task.sleep(nanoseconds: 300_000_000)
		#expect(recorder.lock.withLock { recorder.sends.map(\.value) } == [7])
	}
}

/// Finding 8: App Transport Security, which applies to the agent through the bundle's
/// Info.plist, refused plain HTTP to a qualified LMS name such as nas.lan (-1022, measured).
@Suite struct TransportSecurity {
	@Test func plainHTTPToAnyServerName() throws {
		let url = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Resources/Info.plist")
		let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
		let ats = plist?["NSAppTransportSecurity"] as? [String: Any]
		#expect(ats?["NSAllowsArbitraryLoads"] as? Bool == true)
		// with this key present macOS ignores NSAllowsArbitraryLoads (measured: still -1022)
		#expect(ats?["NSAllowsLocalNetworking"] == nil)
	}
}

/// Finding 9: install.sh writes the session-ending marker so the agent does not reopen the old
/// menu mid-swap; this is the agent's half.
@Suite struct MenuHoldOff {
	let marker = FileManager.default.temporaryDirectory.appendingPathComponent("lyrionplay-ending-\(UUID().uuidString)")

	@Test func aFreshMarkerHoldsTheAgentOffForAMinute() throws {
		defer { try? FileManager.default.removeItem(at: marker) }
		#expect(!MenuPresence.holdsOff(marker: marker)) // control: no marker
		FileManager.default.createFile(atPath: marker.path, contents: nil)
		#expect(MenuPresence.holdsOff(marker: marker))
		#expect(MenuPresence.holdsOff(now: Date().addingTimeInterval(59), marker: marker))
		#expect(!MenuPresence.holdsOff(now: Date().addingTimeInterval(61), marker: marker))
	}
}

/// Review of finding 1's fix: the agent cleared its "follow later" flag whenever it stopped the
/// engine, so after a restart on the held device (a settings change during exclusive play) an
/// output chosen meanwhile was never followed. The state now lives here, and only resolve changes
/// it; the agent's stop and restart have nothing to clear.
@Suite struct OutputFollowing {
	/// the probe while the engine holds the FiiO, and the user has picked the speakers (or macOS has)
	var speakersDefault: [DeviceCaps] {
		var list = devices
		for i in list.indices { list[i].isDefault = list[i].uid == speakers.uid }
		return list
	}
	var fiioDefault: [DeviceCaps] {
		var list = devices
		for i in list.indices { list[i].isDefault = list[i].uid == fiio.uid }
		return list
	}

	@Test func anOutputChosenDuringTheHoldIsFollowedAfterARestart() {
		var follow = OutputFollow()
		let settings = Settings() // follows the macOS output
		// playing exclusively on the FiiO; the speakers are now the macOS output
		#expect(follow.resolve(settings, in: speakersDefault, holding: fiio.uid)?.uid == fiio.uid)
		#expect(follow.deferred)
		// a settings change restarts the engine on the FiiO: the new engine holds nothing yet,
		// and nothing the agent does to stop or start it touches `follow`
		#expect(follow.shouldReconcile(holding: nil))  // the tick reconciles...
		#expect(follow.resolve(settings, in: speakersDefault, holding: nil)?.uid == speakers.uid) // ...onto the speakers
		#expect(!follow.deferred)
		#expect(!follow.shouldReconcile(holding: nil)) // and stops looking
	}

	@Test func theDefaultComingBackNeedsNoMove() {
		var follow = OutputFollow()
		let settings = Settings()
		_ = follow.resolve(settings, in: speakersDefault, holding: fiio.uid)
		// the engine let go and macOS put the FiiO back as its output
		#expect(follow.resolve(settings, in: fiioDefault, holding: nil)?.uid == fiio.uid)
		#expect(!follow.deferred)
	}

	@Test func stillHeldMeansWait() {
		var follow = OutputFollow()
		_ = follow.resolve(Settings(), in: speakersDefault, holding: fiio.uid)
		#expect(!follow.shouldReconcile(holding: fiio.uid))
	}

	/// a device whose own player is switched on is not kept by the hold, so nothing waits for it
	@Test func aDeviceWithItsOwnPlayerNeverDefers() {
		var follow = OutputFollow()
		var settings = Settings()
		settings.players[fiio.uid] = player(fiio, volume: .software)
		#expect(follow.resolve(settings, in: speakersDefault, holding: fiio.uid)?.uid == speakers.uid)
		#expect(!follow.deferred)
		// control: with its own player off, the same probe does defer
		#expect(follow.resolve(Settings(), in: speakersDefault, holding: fiio.uid)?.uid == fiio.uid && follow.deferred)
	}

	/// /code-review 2026-10-14, finding 3: switched off while it waited, the wait never ended, and the
	/// agent reconciled (a device probe) every 2 s until it was on again
	@Test func switchedOffEndsTheWait() {
		var follow = OutputFollow()
		_ = follow.resolve(Settings(), in: speakersDefault, holding: fiio.uid)
		#expect(follow.deferred)                                   // control: it waits
		var off = Settings()
		off.players[PlayerKey.follow]?.enabled = false
		#expect(follow.resolve(off, in: speakersDefault, holding: nil) == nil)
		#expect(!follow.deferred && !follow.shouldReconcile(holding: nil))
	}

	@Test func noDeviceClearsIt() {
		var follow = OutputFollow()
		_ = follow.resolve(Settings(), in: speakersDefault, holding: fiio.uid)
		#expect(follow.resolve(Settings(), in: [], holding: nil) == nil)
		#expect(!follow.deferred)
	}
}

/// Review after 0.2.2, finding 1: a status check that began before a server change in Settings
/// put the old server back when it ended, and the agent then reused it for good (a server that
/// answers is never checked against the setting again), so the menu and the Mac's volume keys
/// went to the old server while the engine played on the new one. The rule lives here; the
/// agent's check reports which setting it began with.
@Suite struct ServerChoosing {
	let a = LMSServer(host: "plex", webPort: 9000, name: "Simons Music")
	let b = LMSServer(host: "other", webPort: 9000, name: "Other")

	@Test func aCheckBegunBeforeAServerChangeIsDropped() {
		var choice = ServerChoice(setting: "")
		let kept = choice.checked(setting: "", found: a) // found automatically
		#expect(kept && choice.server == a)
		let begun = choice.setting                      // a check of it begins...
		choice.update(setting: "other")                 // ...Settings saves another server...
		#expect(choice.server == nil)
		let late = choice.checked(setting: begun, found: a) // ...and the check ends: dropped
		#expect(!late)
		#expect(choice.server == nil)
		let next = choice.checked(setting: choice.setting, found: b) // the next check uses the new one
		#expect(next)
		#expect(choice.server == b)
	}

	@Test func theSameSettingSavedAgainKeepsTheServer() {
		var choice = ServerChoice(setting: "plex")
		choice.checked(setting: "plex", found: a)
		choice.update(setting: "plex") // a rename or a device change saves the settings too
		#expect(choice.server == a)
	}

	@Test func noAnswerForgetsTheServer() {
		var choice = ServerChoice(setting: "")
		choice.checked(setting: "", found: a)
		let none = choice.checked(setting: "", found: nil)
		#expect(none)
		#expect(choice.server == nil)
	}

	/// /code-review 2026-10-11, finding 7: the old server's word on the player (connected, mode, now
	/// playing) was cleared by the agent, outside this type and its tests
	@Test func aServerChangeForgetsWhatTheOldServerSaid() {
		var choice = ServerChoice(setting: "plex")
		let mac = "02:00:00:00:00:01"
		choice.checked(setting: "plex", found: a, states: [mac: LMSClient.PlayerState(connected: true, mode: "play")])
		#expect(choice.playerStates[mac]?.mode == "play")
		choice.update(setting: "plex")                  // saved again, same server: kept
		#expect(choice.playerStates[mac]?.mode == "play")
		choice.update(setting: "other")
		#expect(choice.playerStates.isEmpty)
		choice.checked(setting: "plex", found: a, states: [mac: LMSClient.PlayerState(connected: true, mode: "play")])
		#expect(choice.playerStates.isEmpty)            // a late check of the old one: dropped
		choice.checked(setting: "other", found: nil, states: [mac: LMSClient.PlayerState(connected: true)])
		#expect(choice.playerStates.isEmpty)            // no server, no state
	}

	/// /code-review 2026-10-11, finding 6: after a change, the agent waited out its 5 s cadence
	/// before checking the new server (live 2026-10-11: 5.15 s after the stale reply was dropped).
	/// It checks at once when update says the setting changed, or when a check is dropped.
	@Test func aChangeAndADroppedCheckSaySo() {
		var choice = ServerChoice(setting: "plex")
		let same = choice.update(setting: "plex")
		let changed = choice.update(setting: "other")
		let late = choice.checked(setting: "plex", found: a)
		let current = choice.checked(setting: "other", found: b)
		#expect(!same && changed)
		#expect(!late && current)
	}

	@Test func changedAndBackAcceptsTheCheck() {
		var choice = ServerChoice(setting: "plex")
		choice.update(setting: "other")
		choice.update(setting: "plex")
		let kept = choice.checked(setting: "plex", found: a) // it is the setting in force
		#expect(kept)
		#expect(choice.server == a)
	}
}

/// agent.log's LMS lines (A STALLED SERVER IS NOT A FINDING: they are how a stall is seen), driven
/// the way refreshLMS drives them: each check is timed, and a kept one says which server is used
@Suite struct ServerCheckLogging {
	let a = LMSServer(host: "plex", webPort: 9000, name: "Simons Music")
	let b = LMSServer(host: "other", webPort: 9000, name: "Other")
	let asleep = LMSServer(host: "192.0.2.1", webPort: 9000, name: nil) // a typed host, no discovery reply
	/// what a request no one answers takes: the 4 s URLRequest timeout, and a little over it (never
	/// 4.0 exactly: /code-review 2026-10-11 (3), finding 4)
	let timedOut: TimeInterval = 4.003

	/// one kept check of `found` whose server took `answer` s (nil: none to ask) and answered or not
	func check(_ log: inout LMSCheckLog, answer: TimeInterval?, found: LMSServer?, answered: Bool) -> [String] {
		log.ended(.kept(answered: answered, answer: answer), found: found)
	}

	/// /code-review 2026-10-11 (2), finding 1: a typed server that does not answer took 6.0 s a
	/// check (2 s discovery + the 4 s players timeout, measured against 192.0.2.1), so 0.2.7 wrote a
	/// line per check, every ~6 s, until the agent restarted. Its time is now the request's alone.
	@Test func aServerThatDoesNotAnswerIsLoggedOnceNotPerCheck() {
		var log = LMSCheckLog()
		var lines: [String] = []
		for _ in 0..<10 { lines += check(&log, answer: timedOut, found: asleep, answered: false) }
		#expect(lines == ["LMS check of 192.0.2.1 (192.0.2.1:9000) took 4.0 s",
						  "LMS: 192.0.2.1 (192.0.2.1:9000) did not answer"])
	}

	/// a stall that ends: its first slow check, then one line when checks are back under 2 s
	@Test func aStallIsLoggedWhereItBeginsAndWhereItEnds() {
		var log = LMSCheckLog()
		var lines: [String] = []
		for answer in [0.03, 5.0, 5.5, 4.2, 0.03, 0.03] { lines += check(&log, answer: answer, found: a, answered: true) }
		#expect(lines == ["LMS: using Simons Music (plex:9000)",
						  "LMS check of Simons Music (plex:9000) took 5.0 s",
						  "LMS checks of Simons Music (plex:9000) back under 2 s (0.03 s), after 3 slower, the slowest 5.5 s"])
	}

	/// /code-review 2026-10-11 (3), finding 2: the line was the requests' own 4 s timeout, so a known
	/// server answering late (the stall rule's case: a check outlasting the 2 s tick) wrote nothing;
	/// only a request that got no answer could cross it
	@Test func aLateAnswerIsLogged() {
		var log = LMSCheckLog()
		var lines: [String] = []
		for answer in [0.03, 2.6, 3.4, 0.04] { lines += check(&log, answer: answer, found: a, answered: true) }
		#expect(lines == ["LMS: using Simons Music (plex:9000)",
						  "LMS check of Simons Music (plex:9000) took 2.6 s",
						  "LMS checks of Simons Music (plex:9000) back under 2 s (0.04 s), after 2 slower, the slowest 3.4 s"])
	}

	/// /code-review 2026-10-11 (3), finding 2: the server the agent knew stops answering (setting
	/// automatic): its request times out, then discovery finds none. The quick discovery ended the
	/// run as "LMS checks of no server back under 4 s …, the slowest 4.0 s", a stall that was none.
	@Test func aServerGoneIsItsSlowLineAndDidNotAnswer() {
		var log = LMSCheckLog()
		var lines = check(&log, answer: 0.03, found: a, answered: true)
		lines += check(&log, answer: timedOut, found: a, answered: false)
		for _ in 0..<3 { lines += check(&log, answer: nil, found: nil, answered: false) }
		#expect(lines == ["LMS: using Simons Music (plex:9000)", "LMS check of Simons Music (plex:9000) took 4.0 s",
						  "LMS: Simons Music (plex:9000) did not answer"])
	}

	/// a run is one server's: discovery then finding another server ends it unsaid, never under that
	/// server's name
	@Test func aRunEndsUnsaidWhenAnotherServerIsChecked() {
		var log = LMSCheckLog()
		var lines = check(&log, answer: 0.03, found: a, answered: true)
		lines += check(&log, answer: 3.0, found: a, answered: true)
		lines += check(&log, answer: timedOut, found: a, answered: false)
		lines += check(&log, answer: 0.02, found: b, answered: true)
		#expect(lines == ["LMS: using Simons Music (plex:9000)", "LMS check of Simons Music (plex:9000) took 3.0 s",
						  "LMS: Simons Music (plex:9000) did not answer", "LMS: using Other (other:9000)"])
	}

	/// inline review 2026-10-11: a run can end in a quick FAILURE (a stall, then LMS restarting
	/// refuses at once); the end line said "quick again", read as "answering again" beside the
	/// "did not answer" line under it
	@Test func aStallEndingInAQuickFailureSaysUnder2sNotAnswering() {
		var log = LMSCheckLog()
		var lines: [String] = []
		lines += check(&log, answer: 0.03, found: a, answered: true)
		lines += check(&log, answer: 5.0, found: a, answered: true)
		lines += check(&log, answer: 0.01, found: a, answered: false)
		#expect(lines == ["LMS: using Simons Music (plex:9000)", "LMS check of Simons Music (plex:9000) took 5.0 s",
						  "LMS checks of Simons Music (plex:9000) back under 2 s (0.01 s), after 1 slower, the slowest 5.0 s",
						  "LMS: Simons Music (plex:9000) did not answer"])
	}

	/// /code-review 2026-10-11 (2), finding 3: the server line was written only when the server
	/// changed from the one before the check, and the agent starts with none, so a start with no
	/// server answering wrote nothing at all. Discovery's own 2 s wait is not a slow server.
	@Test func noServerAtStartIsLogged() {
		var log = LMSCheckLog()
		let lines = check(&log, answer: nil, found: nil, answered: false) + check(&log, answer: nil, found: nil, answered: false)
		#expect(lines == ["LMS: no server found"])
	}

	/// the same, after the setting changes: update() forgets the server before the check, so a typed
	/// host that does not answer wrote nothing
	@Test func aChangedSettingThatDoesNotAnswerIsLogged() {
		var log = LMSCheckLog()
		var lines = check(&log, answer: 0.03, found: a, answered: true)
		log.settingChanged()
		lines += check(&log, answer: timedOut, found: asleep, answered: false)
		#expect(lines == ["LMS: using Simons Music (plex:9000)", "LMS check of 192.0.2.1 (192.0.2.1:9000) took 4.0 s",
						  "LMS: 192.0.2.1 (192.0.2.1:9000) did not answer"])
	}

	/// controls: a server lost and found again is said once each way; the same one checked again is
	/// not. With what a timeout takes: 4.0 there was under the old 4 s line, and hid finding 2.
	@Test func eachChangeOfServerOnce() {
		var log = LMSCheckLog()
		var lines: [String] = []
		lines += check(&log, answer: 0.03, found: a, answered: true)
		lines += check(&log, answer: 0.03, found: a, answered: true)
		lines += check(&log, answer: timedOut, found: a, answered: false) // the players request timed out
		lines += check(&log, answer: nil, found: nil, answered: false)     // and discovery finds none
		lines += check(&log, answer: 0.03, found: a, answered: true)
		#expect(lines == ["LMS: using Simons Music (plex:9000)", "LMS check of Simons Music (plex:9000) took 4.0 s",
						  "LMS: Simons Music (plex:9000) did not answer", "LMS: using Simons Music (plex:9000)"])
	}

	/// /code-review 2026-10-11 (2), finding 5: a check both slow and dropped wrote "took" and then
	/// "dropped after", one event in two lines; the dropped line carries the time
	@Test func aSlowDroppedCheckIsOneLine() {
		var log = LMSCheckLog()
		var lines = check(&log, answer: 0.03, found: a, answered: true)
		log.settingChanged()
		lines += log.ended(.dropped(began: "", now: "other", took: 5.1), found: a)
		#expect(lines == ["LMS: using Simons Music (plex:9000)",
						  "LMS check of Simons Music (plex:9000) dropped after 5.1 s: begun with server setting \"\", now \"other\""])
	}

	/// a run of slow checks belongs to the setting it was checked under: after a change, the new
	/// server's first quick check did not end the OLD server's run under the new server's name
	@Test func aSettingChangeEndsTheRunUnsaid() {
		var log = LMSCheckLog()
		var lines: [String] = []
		lines += check(&log, answer: 0.03, found: a, answered: true)
		lines += check(&log, answer: 5.0, found: a, answered: true)
		log.settingChanged()
		lines += check(&log, answer: 0.03, found: b, answered: true)
		#expect(lines == ["LMS: using Simons Music (plex:9000)", "LMS check of Simons Music (plex:9000) took 5.0 s",
						  "LMS: using Other (other:9000)"])
	}
}
