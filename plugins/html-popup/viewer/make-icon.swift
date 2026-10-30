// Render an SVG to a square RGBA PNG with a transparent background.
// Usage: swift make-icon.swift <in.svg> <out.png> <pixels>
// qlmanage thumbnails flatten SVG transparency onto white, hence this.
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), size > 0 else {
  FileHandle.standardError.write(
    Data("usage: make-icon.swift <in.svg> <out.png> <pixels>\n".utf8))
  exit(2)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
  FileHandle.standardError.write(Data("cannot load \(args[1])\n".utf8))
  exit(1)
}
guard
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
  let context = NSGraphicsContext(bitmapImageRep: rep)
else {
  FileHandle.standardError.write(Data("cannot create bitmap\n".utf8))
  exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.set()
NSRect(x: 0, y: 0, width: size, height: size).fill()
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write(Data("cannot encode PNG\n".utf8))
  exit(1)
}
do {
  try png.write(to: URL(fileURLWithPath: args[2]))
} catch {
  FileHandle.standardError.write(Data("cannot write \(args[2]): \(error)\n".utf8))
  exit(1)
}
