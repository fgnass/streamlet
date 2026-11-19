import AppKit
import SwiftUI

/// Colors of Streamlet's own surfaces. All player surfaces are dark; the color of the
/// current cover appears only as an accent (play button, progress line, glow).
enum Theme {
    static let panel = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let panelNS = NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)
    static let text = Color(red: 0.95, green: 0.95, blue: 0.96)
    static let secondaryText = Color(red: 0.60, green: 0.60, blue: 0.64)
    static let hairline = Color.white.opacity(0.07)
    static let track = Color.white.opacity(0.12)
}

/// The two accent colors of a track. `accent` is the main color; `accent2` is the start of
/// the progress gradient.
struct Palette: Equatable {
    var accent: NSColor
    var accent2: NSColor

    var accentColor: Color { Color(nsColor: accent) }
    var accent2Color: Color { Color(nsColor: accent2) }

    static let fallback = Palette(
        accent: NSColor(srgbRed: 1.0, green: 0.54, blue: 0.24, alpha: 1),
        accent2: NSColor(srgbRed: 0.82, green: 0.27, blue: 0.50, alpha: 1)
    )

    /// A palette from one color, for example the color of a service icon.
    init(single color: NSColor) {
        let c = Self.readable(color.usingColorSpace(.sRGB) ?? color)
        accent = c
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        accent2 = NSColor(hue: (h + 0.92).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b * 0.85, alpha: 1)
    }

    init(accent: NSColor, accent2: NSColor) {
        self.accent = accent
        self.accent2 = accent2
    }

    /// Finds the two strongest hues of an image. Returns nil for an image without color
    /// (black and white, gray), so the caller can use another source.
    static func from(_ image: NSImage) -> Palette? {
        guard let pixels = samplePixels(of: image, size: 32) else { return nil }
        let binCount = 18
        var weights = [CGFloat](repeating: 0, count: binCount)
        var sums = [(r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0), count: binCount)

        for p in pixels {
            let color = NSColor(srgbRed: p.r, green: p.g, blue: p.b, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            guard s > 0.22, v > 0.18 else { continue }
            let weight = s * s * v
            let bin = min(binCount - 1, Int(h * CGFloat(binCount)))
            weights[bin] += weight
            sums[bin].r += p.r * weight
            sums[bin].g += p.g * weight
            sums[bin].b += p.b * weight
        }

        let total = weights.reduce(0, +)
        guard total > CGFloat(pixels.count) * 0.01 else { return nil }

        func color(ofBin i: Int) -> NSColor {
            let w = weights[i]
            return NSColor(srgbRed: sums[i].r / w, green: sums[i].g / w, blue: sums[i].b / w, alpha: 1)
        }

        let order = weights.indices.sorted { weights[$0] > weights[$1] }
        let first = order[0]
        let primary = readable(color(ofBin: first))

        // The second color must be a clearly different hue with real weight in the image.
        let second = order.dropFirst().first { i in
            let distance = min(abs(i - first), binCount - abs(i - first))
            return distance >= 2 && weights[i] >= weights[first] * 0.12
        }
        guard let second else { return Palette(single: primary) }
        return Palette(accent: primary, accent2: readable(color(ofBin: second)))
    }

    /// Makes a color bright and saturated enough to work as an accent on the dark panel.
    private static func readable(_ color: NSColor) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(max(s, 0.45), 0.85), brightness: max(b, 0.82), alpha: 1)
    }

    private static func samplePixels(of image: NSImage, size: Int) -> [(r: CGFloat, g: CGFloat, b: CGFloat)]? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        var out: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []
        out.reserveCapacity(size * size)
        for i in 0..<(size * size) {
            let alpha = CGFloat(bytes[i * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            out.append((
                CGFloat(bytes[i * 4]) / 255 / alpha,
                CGFloat(bytes[i * 4 + 1]) / 255 / alpha,
                CGFloat(bytes[i * 4 + 2]) / 255 / alpha
            ))
        }
        return out
    }
}

/// Streaming services that Streamlet knows by name.
enum KnownService {
    static let all: [(name: String, url: String)] = [
        ("Spotify", "https://open.spotify.com"),
        ("SoundCloud", "https://soundcloud.com"),
        ("Deezer", "https://deezer.com"),
        ("YouTube Music", "https://music.youtube.com"),
        ("Apple Music", "https://music.apple.com"),
        ("Tidal", "https://tidal.com"),
        ("Amazon Music", "https://music.amazon.com"),
        ("Bandcamp", "https://bandcamp.com"),
        ("Last.fm", "https://last.fm"),
    ]

    /// The display name for a service URL: a known name, otherwise the host without "www.".
    static func name(for urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        for service in all {
            guard let knownHost = URL(string: service.url)?.host?.lowercased() else { continue }
            if bare == knownHost || bare.hasSuffix("." + knownHost) { return service.name }
        }
        if bare.hasSuffix("youtube.com") { return "YouTube" }
        // Amazon Music has one host per country: music.amazon.de, music.amazon.co.uk, ...
        if bare.hasPrefix("music.amazon.") { return "Amazon Music" }
        return bare
    }
}
