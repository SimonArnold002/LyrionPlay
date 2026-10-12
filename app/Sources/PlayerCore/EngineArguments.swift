import Foundation

/// Builds squeezelite's command line from the settings and the device's probed capabilities.
/// Pure: the same inputs always give the same arguments, so a change is easy to detect.
public enum EngineArguments {
	/// LMS's model stays "squeezelite" (BASE_CAP in engine/slimproto.c); this is the ModelName.
	/// Material Skin picks a player's icon by model, then by modelname, and "SqueezeLiteMac" is its
	/// Apple icon (lms-material player-icons.json). LMS shows it as the player's model name. It
	/// differs from the app name on purpose (repo ledger, MODEL NAME IS SqueezeLiteMac).
	public static let modelName = "SqueezeLiteMac"

	/// LMS's pcm rate-code table stops at 384 kHz and sends any higher rate as 44.1 kHz
	/// (repo ledger, THE 384K CAP), so MaxSampleRate is never reported above it.
	public static let lmsPCMRateCap = 384_000

	public static func build(settings: Settings, device: DeviceCaps, mac: String, nameFile: String,
							 logFile: String) -> [String] {
		let options = settings.options(for: device)
		var args = [
			"-o", device.uid,
			"-M", modelName,
			"-m", mac,
			"-N", nameFile,
			"-Z", String(min(device.maxRate, lmsPCMRateCap)),
			// E: resample only when the device lacks the track's rate
			"-R", "\(settings.resampleQuality)E",
			"-a", "0:\(options.exclusive ? 1 : 0)",
			"-d", "all=\(settings.logLevel)",
			"-f", logFile,
		]
		if !settings.server.isEmpty {
			args += ["-s", settings.server]
		}
		if settings.idleSeconds > 0 {
			args += ["-C", String(settings.idleSeconds)]
		}
		// .fixed: no -V, so the engine never touches the device's level, even on an audg LMS sends
		// before the agent has set it to fixed
		if options.volume == .device {
			args.append("-V")
		}
		if options.rateSwitchDelayMs > 0 {
			// the delay rides on -r, with the probed rates so nothing else changes
			args += ["-r", device.rates.map(String.init).joined(separator: ",") + ":\(options.rateSwitchDelayMs)"]
		}
		if options.dop {
			// last: -D takes an optional value, so nothing that is not an option may follow it
			args.append("-D")
		}
		return args
	}
}
