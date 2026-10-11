import Foundation

/// The running bundle's version: CFBundleShortVersionString is VERSION (the one place it is set),
/// CFBundleVersion the build's timestamp, both written by scripts/build.sh.
public enum AppVersion {
	public static var version: String { info("CFBundleShortVersionString") ?? "dev" }
	public static var build: String { info("CFBundleVersion") ?? "dev" }
	/// "0.1.1 (202610101230)"
	public static var description: String { "\(version) (\(build))" }

	static func info(_ key: String) -> String? { Bundle.main.infoDictionary?[key] as? String }
}
