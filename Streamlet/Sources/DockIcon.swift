import AppKit
import CoreImage

/// Images that ship with the app. The release build copies them into the app bundle;
/// debug builds read them from the source folder.
enum BundledImage {
    static func named(_ name: String) -> NSImage? {
        url(of: name + ".png").flatMap { NSImage(contentsOf: $0) }
    }

    /// The URL of a file or folder in the resources, for example "DockTile.png".
    static func url(of name: String) -> URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/\(name)")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
        #else
        return nil
        #endif
    }
}

/// The dock icon while a service is open: the dark tile of the app icon with the
/// service icon stamped on it, and a soft glow in the colors of the service icon.
/// It works for any service, because only the tile is prepared in advance.
enum DockIcon {
    private static let size: CGFloat = 1024
    /// The tile of the app icon covers this square of the 1024 px image.
    private static let tileRect = CGRect(x: 90, y: 90, width: 844, height: 844)
    private static let tile = BundledImage.named("DockTile")
    private static let ciContext = CIContext()
    /// Opacity of the glow from the edge of the service icon.
    private static let glowStrength: CGFloat = 0.8

    static func make(serviceIcon: NSImage) -> NSImage? {
        guard let tile = cgImage(of: tile),
              let icon = cgImage(of: serviceIcon),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let pixels = Int(size)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        let canvas = CGRect(x: 0, y: 0, width: size, height: size)
        context.draw(tile, in: canvas)

        let stampSide = tileRect.width * 0.60
        let stamp = CGRect(
            x: tileRect.midX - stampSide / 2, y: tileRect.midY - stampSide / 2,
            width: stampSide, height: stampSide)

        let corner = stampSide * 0.22
        let shape = CGPath(roundedRect: stamp, cornerWidth: corner, cornerHeight: corner, transform: nil)

        // Glow, only on the tile. It continues the colors at the edge of the service
        // icon, so a white logo in the middle does not color it.
        context.saveGState()
        context.setBlendMode(.sourceAtop)
        if let glow = edgeGlow(of: icon, in: stamp, shape: shape, corner: corner) {
            context.setAlpha(glowStrength)
            context.draw(glow, in: canvas)
        } else if let palette = Palette.from(serviceIcon) {
            // The edge is transparent (a logo without a background): use the colors
            // of the logo instead. Icons without color get no extra glow.
            glow(palette.accent2, at: CGPoint(x: tileRect.minX + tileRect.width * 0.32, y: tileRect.minY + tileRect.height * 0.30),
                 radius: tileRect.width * 0.55, alpha: 0.18, in: context)
            glow(palette.accent, at: CGPoint(x: tileRect.midX, y: tileRect.midY + tileRect.height * 0.04),
                 radius: tileRect.width * 0.50, alpha: 0.30, in: context)
        }
        context.restoreGState()

        // The stamp: the service icon with rounded corners and a soft shadow.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.55))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(shape)
        context.clip()
        context.draw(icon, in: aspectFit(CGSize(width: icon.width, height: icon.height), in: stamp))
        context.endTransparencyLayer()
        context.restoreGState()

        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: size / 2, height: size / 2))
    }

    /// A blurred ring of the outer edge of the icon. Made at 1/8 size, so the blur is
    /// cheap and smooth. Returns nil when the edge is mostly transparent.
    private static func edgeGlow(of icon: CGImage, in stamp: CGRect, shape: CGPath, corner: CGFloat) -> CGImage? {
        let scale: CGFloat = 1.0 / 8
        let side = Int(size * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let small = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        small.interpolationQuality = .high
        small.scaleBy(x: scale, y: scale)

        let width = stamp.width * 0.10
        let innerRect = stamp.insetBy(dx: width, dy: width)
        let inner = CGPath(roundedRect: innerRect, cornerWidth: max(corner - width, 0), cornerHeight: max(corner - width, 0), transform: nil)
        let ring = CGMutablePath()
        ring.addPath(shape)
        ring.addPath(inner)
        small.addPath(ring)
        small.clip(using: .evenOdd)
        small.draw(icon, in: aspectFit(CGSize(width: icon.width, height: icon.height), in: stamp))

        // How much of the ring the icon covers.
        guard let data = small.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var alphaSum = 0.0
        for i in 0..<(side * side) { alphaSum += Double(bytes[i * 4 + 3]) / 255 }
        let ringArea = Double((stamp.width * stamp.height - innerRect.width * innerRect.height) * scale * scale)
        guard alphaSum > ringArea * 0.5, let ringImage = small.makeImage() else { return nil }

        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let blurred = CIImage(cgImage: ringImage)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 12)
            .cropped(to: extent)
        return ciContext.createCGImage(blurred, from: extent)
    }

    private static func glow(_ color: NSColor, at center: CGPoint, radius: CGFloat, alpha: CGFloat, in context: CGContext) {
        let base = color.usingColorSpace(.sRGB) ?? color
        // Smooth falloff: several stops on an ease-out curve, no visible edge.
        let steps = 8
        let colors = (0...steps).map { i -> CGColor in
            let t = CGFloat(i) / CGFloat(steps)
            return base.withAlphaComponent(alpha * pow(1 - t, 2.2)).cgColor
        }
        let locations = (0...steps).map { CGFloat($0) / CGFloat(steps) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
        else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private static func cgImage(of image: NSImage?) -> CGImage? {
        guard let image else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
