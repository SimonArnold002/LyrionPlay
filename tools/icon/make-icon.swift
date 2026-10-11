// Renders the app icon from the glyph SVG: a rounded square in Lyrion's green with the glyph in
// white, at every size an .iconset needs. scripts/build.sh then runs iconutil on the result.
//   make-icon <glyph.svg> <out.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let glyph = NSImage(contentsOfFile: args[1]) else {
	FileHandle.standardError.write(Data("usage: make-icon <glyph.svg> <out.iconset>\n".utf8))
	exit(2)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let green = NSColor(srgbRed: 0x58 / 255.0, green: 0x9e / 255.0, blue: 0x81 / 255.0, alpha: 1) // Lyrion #589e81

func render(_ pixels: Int) -> Data {
	let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
							   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
							   bytesPerRow: 0, bitsPerPixel: 0)!
	let s = CGFloat(pixels) / 1024
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
	// Apple's macOS icon grid: an 824-point rounded square centred on a 1024 canvas
	let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
	green.setFill()
	NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s).fill()
	// the glyph, white, 62% of the tile's width, centred
	let width = tile.width * 0.62, height = width * glyph.size.height / glyph.size.width
	let white = NSImage(size: glyph.size, flipped: false) { rect in
		glyph.draw(in: rect)
		NSColor.white.setFill()
		rect.fill(using: .sourceAtop)
		return true
	}
	white.draw(in: NSRect(x: tile.midX - width / 2, y: tile.midY - height / 2, width: width, height: height))
	NSGraphicsContext.restoreGraphicsState()
	return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
	try render(points).write(to: out.appendingPathComponent("icon_\(points)x\(points).png"))
	try render(points * 2).write(to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
