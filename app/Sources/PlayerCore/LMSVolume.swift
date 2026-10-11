import Foundation

/// LMS's volume curve for this player, so a device level can be turned back into a slider position.
///
/// LMS counts squeezelite as a SqueezePlay client (Slim::Player::SqueezePlay). Its
/// getVolumeParameters gives totalVolumeRange -74 dB, stepPoint 25 and stepFraction 0.5, and
/// Squeezebox2::getVolume draws two straight lines: -74 dB at 0 up to -37 dB at 25, then up to
/// 0 dB at 100. LMS sends that level as the 16.16 gain in `audg`, and with -V the engine puts
/// exactly that many dB on the device, clamped to the device's range (output_coreaudio.c
/// apply_volume). Volume 0, or a negative volume, means muted.
public enum LMSVolume {
	static let bottomDB = -74.0
	static let stepPoint = 25.0
	static let stepDB = -37.0 // bottomDB * stepFraction

	/// the level LMS asks for at volume 1...100
	public static func dB(_ volume: Int) -> Double {
		let v = Double(min(max(volume, 1), 100))
		if v > stepPoint {
			return (0 - stepDB) / (100 - stepPoint) * (v - 100)
		}
		return (stepDB - bottomDB) / stepPoint * v + bottomDB
	}

	/// the slider position whose level is nearest to a device level; at least 1, because a
	/// level is not a mute
	public static func volume(forDB level: Double) -> Int {
		var best = 1
		var bestDistance = Double.infinity
		for v in 1...100 {
			let distance = abs(dB(v) - level)
			if distance < bestDistance {
				best = v
				bestDistance = distance
			}
		}
		return best
	}
}
