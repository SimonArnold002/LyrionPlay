import CoreAudio
import Foundation

/// Read-only CoreAudio lookups for the status line: what the device is actually doing right now.
/// Capabilities (rates, formats, volume) come from the engine's probe instead (DeviceCaps).
public enum CoreAudioQuery {
	static func address(_ selector: AudioObjectPropertySelector,
						_ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
	}

	public static func device(uid: String) -> AudioDeviceID? {
		var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
		var cfUID = uid as CFString
		var id = AudioDeviceID(kAudioObjectUnknown)
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
			AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
									   UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
		}
		return status == noErr && id != kAudioObjectUnknown ? id : nil
	}

	public static func nominalRate(_ device: AudioDeviceID) -> Int? {
		var address = address(kAudioDevicePropertyNominalSampleRate)
		var rate = Float64(0)
		var size = UInt32(MemoryLayout<Float64>.size)
		guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
		return Int(rate.rounded())
	}

	/// the process holding exclusive (hog) mode, or -1
	public static func hogOwner(_ device: AudioDeviceID) -> pid_t? {
		var address = address(kAudioDevicePropertyHogMode)
		var owner = pid_t(-1)
		var size = UInt32(MemoryLayout<pid_t>.size)
		guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &owner) == noErr else { return nil }
		return owner
	}

	/// "32-bit integer" / "32-bit float", from the first output stream's physical format
	public static func physicalFormat(_ device: AudioDeviceID) -> String? {
		var streamsAddress = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
		var size = UInt32(0)
		guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &size) == noErr,
			  size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return nil }
		var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
		guard AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &size, &streams) == noErr,
			  let stream = streams.first else { return nil }
		var formatAddress = address(kAudioStreamPropertyPhysicalFormat)
		var format = AudioStreamBasicDescription()
		size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
		guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &size, &format) == noErr else { return nil }
		let kind = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "integer"
		return "\(format.mBitsPerChannel)-bit \(kind)"
	}
}

/// Calls back on the main queue when a device is plugged in or out, or the macOS default output
/// changes.
public final class AudioDeviceWatcher {
	private let onChange: () -> Void
	private var addresses = [
		CoreAudioQuery.address(kAudioHardwarePropertyDevices),
		CoreAudioQuery.address(kAudioHardwarePropertyDefaultOutputDevice),
	]
	private lazy var block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }

	public init(onChange: @escaping () -> Void) {
		self.onChange = onChange
		for i in addresses.indices {
			AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], .main, block)
		}
	}

	deinit {
		for i in addresses.indices {
			AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], .main, block)
		}
	}
}
