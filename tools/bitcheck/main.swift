// bitcheck: compares the engine's output tap (LYRIONPLAY_TAP; interleaved Float32 left/right, one file
// per rate) with a reference decode of the source file by Apple's own decoder (ExtAudioFile), which
// is independent of the engine's libFLAC, sample by sample.
//
//   bitcheck <tap.f32> <source audio file>
//
// The two are lined up on their first non-zero frame. Zero frames at the END of the tap are not
// compared: they are the silence after playback was stopped, not part of the track. Any other
// difference, including silence inserted mid-track, is a mismatch.
// Exit 0 = every compared sample identical; 1 = a mismatch; 2 = usage, read or decode error.
import AudioToolbox
import Foundation

func fail(_ message: String) -> Never {
	FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
	exit(2)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: bitcheck <tap.f32> <source audio file>") }

guard let tapData = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else { fail("cannot read \(args[1])") }
let tap: [Float] = tapData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

var fileRef: ExtAudioFileRef?
guard ExtAudioFileOpenURL(URL(fileURLWithPath: args[2]) as CFURL, &fileRef) == noErr, let file = fileRef else {
	fail("cannot open \(args[2])")
}
var fileFormat = AudioStreamBasicDescription()
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)

// decode to interleaved Float32 stereo at the file's own rate (no rate conversion)
var client = AudioStreamBasicDescription(
	mSampleRate: fileFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
	mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
	mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
	mReserved: 0)
guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
							  UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr else {
	fail("cannot set the decode format")
}
var ref = [Float]()
var chunk = [Float](repeating: 0, count: 65536 * 2)
while true {
	var frames = UInt32(65536)
	let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
		var list = AudioBufferList(mNumberBuffers: 1,
								   mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count),
														 mData: raw.baseAddress))
		return ExtAudioFileRead(file, &frames, &list)
	}
	if status != noErr { fail("decode error \(status)") }
	if frames == 0 { break }
	ref.append(contentsOf: chunk[0..<Int(frames) * 2])
}
ExtAudioFileDispose(file)

func firstSoundFrame(_ samples: [Float]) -> Int? {
	samples.firstIndex(where: { $0 != 0 }).map { $0 / 2 }
}
guard let tapStart = firstSoundFrame(tap), let refStart = firstSoundFrame(ref) else {
	fail("no sound in the tap or the reference")
}
let lastSoundSample = tap.lastIndex(where: { $0 != 0 }) ?? 0
let tapEnd = lastSoundSample / 2 + 1
let frames = min(tapEnd - tapStart, ref.count / 2 - refStart)

var mismatches = 0
var firstMismatch: Int?
var maxDiff: Float = 0
for i in 0..<frames * 2 {
	let a = tap[tapStart * 2 + i], b = ref[refStart * 2 + i]
	if a != b {
		mismatches += 1
		if firstMismatch == nil { firstMismatch = i }
		maxDiff = max(maxDiff, abs(a - b))
	}
}

let rate = fileFormat.mSampleRate
let bits = fileFormat.mBitsPerChannel
print(String(format: "source: %.0f Hz %@, %d frames decoded; tap: %d frames, sound from frame %d",
			 rate, bits > 0 ? "\(bits)-bit" : "compressed", ref.count / 2, tap.count / 2, tapStart))
print(String(format: "compared %d frames (%.2f s) from source frame %d: %d of %d samples differ",
			 frames, Double(frames) / rate, refStart, mismatches, frames * 2))
if let i = firstMismatch {
	print(String(format: "first difference at sample %d (frame %d, %@): tap %.9g, source %.9g; largest %.3g",
				 i, i / 2, i % 2 == 0 ? "left" : "right", tap[tapStart * 2 + i], ref[refStart * 2 + i], maxDiff))
}
print("result: \(mismatches == 0 && frames > 0 ? "BIT-EXACT" : "DIFFERENT")")
exit(mismatches == 0 && frames > 0 ? 0 : 1)
