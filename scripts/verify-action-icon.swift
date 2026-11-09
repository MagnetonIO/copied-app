import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/verify-action-icon.swift IMAGE.png")
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = NSImage(contentsOf: url),
      let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot read icon")
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let checked = pixels.withUnsafeMutableBytes { bytes -> Bool in
    guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
precondition(checked && width == height && width > 0, "Icon must be square")
var opaque = 0
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let alpha = pixels[i + 3]
        if x < width / 10 || x >= width * 9 / 10 || y < height / 10 || y >= height * 9 / 10 {
            precondition(alpha == 0, "System action chrome needs transparent icon margins")
        }
        if alpha > 0 {
            precondition(pixels[i] == pixels[i + 1] && pixels[i + 1] == pixels[i + 2],
                "Action icon must be monochrome, not the full-color app icon")
            opaque += 1
        }
    }
}
let coverage = Double(opaque) / Double(width * height)
precondition(coverage > 0.03 && coverage < 0.4, "Expected a visible glyph, without a filled tile")
print("Action icon verified: \(width)x\(height), transparent margins, monochrome glyph")
