import Foundation

/// The menu app and the player are tied (Simon, 2026-10-09): while the player is on, its menu is
/// there. The menu app holds an exclusive lock on menu.lock for its whole life, and the kernel
/// drops it however the app ends, crash and force quit included. So the agent can tell whether a
/// menu is running without matching names or paths: a reinstall replaces the bundle under a
/// running app, which would break a path match.
public enum MenuPresence {
	public static var lockURL: URL { Paths.support.appendingPathComponent("menu.lock") }

	/// Written by the menu app when it quits because the session is ending (logout, restart,
	/// shutdown), so the agent does not reopen it in the seconds before launchd stops the agent
	/// too. Also written by install.sh before it replaces the menu, so the agent does not reopen
	/// the old copy mid-swap. The agent honours it for a minute only: a logout someone cancels
	/// must not leave the player running with no menu. The menu app removes it when it starts.
	public static var sessionEnding: URL { Paths.support.appendingPathComponent("menu-session-ending") }

	/// The agent: is the sessionEnding marker under a minute old, so the menu must not be reopened?
	public static func holdsOff(now: Date = Date(), marker: URL = sessionEnding) -> Bool {
		guard let written = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date
		else { return false }
		return now.timeIntervalSince(written) < 60
	}

	/// kept open for the life of the menu app: closing it would release the lock
	nonisolated(unsafe) private static var heldDescriptor: Int32 = -1

	/// The menu app, at launch: take the lock. False only when another menu app holds it. Waits
	/// briefly, because the agent's check takes the lock for an instant.
	public static func claim(waiting seconds: Double = 2, lock: URL = lockURL) -> Bool {
		try? Paths.createDirectories()
		let fd = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
		guard fd >= 0 else { return true } // cannot tell: run, rather than leave no menu at all
		let deadline = Date().addingTimeInterval(seconds)
		repeat {
			if flock(fd, LOCK_EX | LOCK_NB) == 0 {
				heldDescriptor = fd
				return true
			}
			usleep(100_000)
		} while Date() < deadline
		close(fd)
		return false
	}

	/// The agent: is a menu app running?
	public static func isRunning(lock: URL = lockURL) -> Bool {
		let fd = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
		guard fd >= 0 else { return true } // cannot tell: never open a second menu
		defer { close(fd) }
		guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
		flock(fd, LOCK_UN)
		return false
	}

	/// tests only: what the kernel does when the menu app exits
	static func release() {
		guard heldDescriptor >= 0 else { return }
		close(heldDescriptor)
		heldDescriptor = -1
	}
}
