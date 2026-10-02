import AppKit
import Foundation

struct Screenshot {
    let filename: String
    let headline: [String]
    let subtitle: [String]
}

let width = 1320
let height = 2868
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("design/app-store/ios/_original")
let output = CommandLine.arguments.dropFirst().first.map {
    URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL
} ?? root.appendingPathComponent("fastlane/screenshots-ios/en-US")
let background = NSColor(srgbRed: 243 / 255, green: 245 / 255, blue: 246 / 255, alpha: 1)
let headlineColor = NSColor(srgbRed: 17 / 255, green: 24 / 255, blue: 29 / 255, alpha: 1)
let secondaryColor = NSColor(srgbRed: 100 / 255, green: 108 / 255, blue: 116 / 255, alpha: 1)

let screenshots = [
    Screenshot(filename: "01_main_list.png",
               headline: ["Your clipboard,", "organized."],
               subtitle: ["Save text, links, and code.", "Keep them ready to reuse."]),
    Screenshot(filename: "02_clipping_detail.png",
               headline: ["Keep useful", "snippets close."],
               subtitle: ["Review, edit, and reuse", "saved text and code."]),
    Screenshot(filename: "03_settings.png",
               headline: ["Make Copied", "your own."],
               subtitle: ["Adjust your preferences.", "Keep your workflow in focus."]),
    Screenshot(filename: "04_search.png",
               headline: ["Find it.", "Use it again."],
               subtitle: ["Search your clippings", "without the scrolling."])
]

func drawLines(_ lines: [String], top: CGFloat, fontSize: CGFloat, lineHeight: CGFloat,
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
    for (index, line) in lines.enumerated() {
        let label = NSAttributedString(string: line, attributes: attributes)
        guard label.size().width <= CGFloat(width - 160) else {
            throw NSError(domain: "StoreScreenshots", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Text exceeds canvas: \(line)"])
        }
        label.draw(in: CGRect(x: 80,
                              y: CGFloat(height) - top - CGFloat(index) * lineHeight - fontSize * 1.4,
                              width: CGFloat(width - 160), height: fontSize * 1.4))
    }
}

func render() throws {
    // Validate the complete source set before replacing any upload assets.
    let originals: [CGImage] = try screenshots.map { screenshot in
        let url = source.appendingPathComponent(screenshot.filename)
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              original.width == width, original.height == height else {
            throw NSError(domain: "StoreScreenshots", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Expected a 1320 x 2868 original: \(url.path)"])
        }
        return original
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (screenshot, original) in zip(screenshots, originals) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "StoreScreenshots", code: 3)
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        background.setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        try drawLines(screenshot.headline, top: 76, fontSize: 94, lineHeight: 108,
                      weight: .bold, color: headlineColor)
        try drawLines(screenshot.subtitle, top: 332, fontSize: 40, lineHeight: 52,
                      weight: .regular, color: secondaryColor)

        let screenWidth: CGFloat = 1060
        let screenHeight = screenWidth * CGFloat(height) / CGFloat(width)
        let rect = CGRect(x: (CGFloat(width) - screenWidth) / 2, y: 105,
                          width: screenWidth, height: screenHeight)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 72, yRadius: 72)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = CGSize(width: 0, height: -16)
        shadow.set()
        NSColor.black.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        // Keep the whole capture, including status, navigation, and search bars.
        outline.addClip()
        context.draw(original, in: rect)
        NSGraphicsContext.restoreGraphicsState()

        guard let rendered = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "StoreScreenshots", code: 4)
        }
        let destination = output.appendingPathComponent(screenshot.filename)
        try png.write(to: destination, options: .atomic)
        print("Rendered \(destination.path)")
    }
}

do {
    try render()
} catch {
    FileHandle.standardError.write(Data("Screenshot rendering failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
