import Foundation

/// One `lyrionplay:format <rate> <pcm|dop>` line from the engine (output_coreaudio.c,
/// ca_report_format): the rate and format of the last track start the device took. CoreAudio sees
/// DoP as PCM at the DSD rate / 16 (repo ledger, NO DOP PROPERTY IN COREAUDIO), so only the engine
/// can say that 176.4 kHz is DSD64.
public struct FormatReport: Equatable, Sendable {
	public var rate: Int
	public var dop: Bool

	public init(rate: Int, dop: Bool) {
		self.rate = rate
		self.dop = dop
	}

	/// nil for any other line
	public init?(line: some StringProtocol) {
		let fields = line.split(separator: " ")
		guard fields.count == 3, fields[0] == "lyrionplay:format", let rate = Int(fields[1]), rate > 0,
			  fields[2] == "pcm" || fields[2] == "dop" else { return nil }
		self.rate = rate
		dop = fields[2] == "dop"
	}

	/// The DSD rate played as DoP (16 x the device rate), while the device is still at the rate this
	/// report names. nil for PCM, and once the device has moved. A DAC keeps its rate after the
	/// engine lets go, so the release has its own line (`FormatLine.idle`), which drops the report.
	public func dsdRate(deviceRate: Int?) -> Int? {
		guard dop, deviceRate == rate else { return nil }
		return rate * 16
	}
}

/// What one engine line says of the format: what plays, or `lyrionplay:format idle`, the engine
/// letting go of the device (the idle release, a lost device), after which the last report no
/// longer holds (/code-review 2026-10-12, finding 3). nil for any other line.
public enum FormatLine: Equatable, Sendable {
	case playing(FormatReport)
	case idle

	public init?(line: some StringProtocol) {
		if line == "lyrionplay:format idle" {
			self = .idle
		} else if let report = FormatReport(line: line) {
			self = .playing(report)
		} else {
			return nil
		}
	}

	/// the report to keep: nil after the release
	public var report: FormatReport? {
		if case .playing(let report) = self { return report }
		return nil
	}
}

extension DeviceCaps {
	/// "DSD64 (2.8224 MHz)": the multiple of 44.1 kHz (48 kHz for that family) and the bit rate.
	/// The rate in full, to 4 places, which is exact for every DSD rate of either family (all are
	/// 64 x 44.1k or 48k x a power of 2): a shortened name differs between the families and the
	/// rates (2.8, 22.4 or 22.5, 3.0 or 3.1), and a DAC reached by DoP may be on either.
	public static func dsd(_ rate: Int) -> String {
		let base = rate % 44100 == 0 ? 44100 : 48000
		return String(format: "DSD%d (%.4f MHz)", rate / base, Double(rate) / 1_000_000)
	}
}
