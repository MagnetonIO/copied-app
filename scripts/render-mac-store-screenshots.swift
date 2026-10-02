import AppKit
import Foundation

struct Screenshot {
    let filename: String
    let crop: CGRect
    let radius: CGFloat
    let headline: String
    let subtitle: String
    let displayHeight: CGFloat
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("fastlane/screenshots/en-US/_original")
let output = CommandLine.arguments.dropFirst().first.map {
    URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL
} ?? root.appendingPathComponent("fastlane/screenshots/en-US")
let width = 2880
let height = 1800
let background = NSColor(srgbRed: 243 / 255, green: 245 / 255, blue: 246 / 255, alpha: 1)
let headlineColor = NSColor(srgbRed: 17 / 255, green: 24 / 255, blue: 29 / 255, alpha: 1)
let secondaryColor = NSColor(srgbRed: 100 / 255, green: 108 / 255, blue: 116 / 255, alpha: 1)

let screenshots = [
    Screenshot(filename: "01_main_window.png",
               crop: CGRect(x: 480, y: 334, width: 1804, height: 1200), radius: 52,
               headline: "Your clipboard, organized.",
               subtitle: "Keep text, links, and images ready to reuse.", displayHeight: 1350),
    Screenshot(filename: "02_popover.png",
               crop: CGRect(x: 1878, y: 78, width: 800, height: 1081), radius: 44,
               headline: "Ready when you need it.",
               subtitle: "Search and reuse clippings from your menu bar.", displayHeight: 1350),
    Screenshot(filename: "03_sync_active.png",
               crop: CGRect(x: 875, y: 611, width: 1123, height: 1063), radius: 32,
               headline: "Your clippings, across devices.",
               subtitle: "Keep your library together with iCloud Sync.", displayHeight: 1280),
    Screenshot(filename: "04_clipboard_settings.png",
               crop: CGRect(x: 813, y: 377, width: 1122, height: 1068), radius: 32,
               headline: "Capture what matters.",
               subtitle: "Choose what Copied saves and which apps to exclude.", displayHeight: 1280)
]

func drawText(_ text: String, top: CGFloat, fontSize: CGFloat,
              weight: NSFont.Weight, color: NSColor) throws {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byClipping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
        .kern: 0
    ]
    let label = NSAttributedString(string: text, attributes: attributes)
    guard label.size().width <= CGFloat(width - 200) else {
        throw NSError(domain: "StoreScreenshots", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Heading exceeds canvas: \(text)"])
    }
    label.draw(in: CGRect(x: 100, y: CGFloat(height) - top - fontSize * 1.4,
                          width: CGFloat(width - 200), height: fontSize * 1.4))
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for screenshot in screenshots {
    let input = source.appendingPathComponent(screenshot.filename)
    guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
          let original = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
          CGRect(x: 0, y: 0, width: original.width, height: original.height).contains(screenshot.crop),
          let cropped = original.cropping(to: screenshot.crop) else {
        throw NSError(domain: "StoreScreenshots", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Missing or invalid original: \(input.path)"])
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let renderContext = CGContext(data: nil, width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: colorSpace,
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw NSError(domain: "StoreScreenshots", code: 3)
    }
    let graphics = NSGraphicsContext(cgContext: renderContext, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    background.setFill()
    CGRect(x: 0, y: 0, width: width, height: height).fill()
    try drawText(screenshot.headline, top: 64, fontSize: 104, weight: .bold, color: headlineColor)
    try drawText(screenshot.subtitle, top: 206, fontSize: 48, weight: .regular, color: secondaryColor)

    let scale = screenshot.displayHeight / screenshot.crop.height
    let size = CGSize(width: screenshot.crop.width * scale, height: screenshot.displayHeight)
    let rect = CGRect(x: (CGFloat(width) - size.width) / 2, y: 110, width: size.width, height: size.height)
    let outline = NSBezierPath(roundedRect: rect, xRadius: screenshot.radius * scale,
                              yRadius: screenshot.radius * scale)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = CGSize(width: 0, height: -20)
    shadow.set()
    NSColor.black.setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    // Mask only wallpaper outside the original window's rounded silhouette.
    outline.addClip()
    graphics.cgContext.draw(cropped, in: rect)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let rendered = renderContext.makeImage(),
          let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "StoreScreenshots", code: 4)
    }
    let destination = output.appendingPathComponent(screenshot.filename)
    try png.write(to: destination, options: .atomic)
    print("Rendered \(destination.path)")
}
