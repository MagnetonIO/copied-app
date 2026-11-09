import AppKit

let destination = CommandLine.arguments.dropFirst().first ??
    "CopiedClipperExtension/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"
let size = 1024
guard let context = CGContext(data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot create action icon context")
}
context.setStrokeColor(CGColor(gray: 0, alpha: 1))
context.setLineCap(.round)
context.setLineJoin(.round)
context.setLineWidth(44)
context.addPath(CGPath(roundedRect: CGRect(x: 274, y: 170, width: 476, height: 684),
    cornerWidth: 52, cornerHeight: 52, transform: nil))
context.strokePath()
context.setLineWidth(38)
context.addPath(CGPath(roundedRect: CGRect(x: 342, y: 610, width: 340, height: 104),
    cornerWidth: 22, cornerHeight: 22, transform: nil))
context.strokePath()
context.setLineWidth(32)
for (end, y) in [(530.0, 550.0), (682.0, 424.0), (682.0, 298.0)] {
    context.move(to: CGPoint(x: 342, y: y))
    context.addLine(to: CGPoint(x: end, y: y))
    context.strokePath()
}
guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode action icon")
}
try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
print("Rendered transparent action glyph: \(destination)")
