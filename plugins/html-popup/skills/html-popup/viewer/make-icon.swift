// Render an SVG to a square RGBA PNG with a transparent background.
// Usage: swift make-icon.swift <in.svg> <out.png> <pixels>
// qlmanage thumbnails flatten SVG transparency onto white, hence this.
import AppKit

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), size > 0 else {
    fail("usage: make-icon.swift <in.svg> <out.png> <pixels>", 2)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    fail("cannot load \(args[1])")
}
guard
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: rep)
else {
    fail("cannot create bitmap")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.set()
NSRect(x: 0, y: 0, width: size, height: size).fill()
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fail("cannot encode PNG")
}
do {
    try png.write(to: URL(fileURLWithPath: args[2]))
} catch {
    fail("cannot write \(args[2]): \(error)")
}
