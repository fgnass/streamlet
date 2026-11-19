import AppKit
import ImageIO
import SwiftUI

/// The app icon that builds itself up: the two blades fly in from the sides and form
/// the S. It plays once when the view appears and then keeps the last frame. With
/// "Reduce motion", or when the frames are missing, it shows the still icon.
struct AnimatedAppIcon: View {
    var size: CGFloat = 92
    /// False shows the finished icon at once, for example over a playing page.
    var plays = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var finished = false

    private static let fps: Double = 30
    private static let frames = loadFrames()
    private static let still = BundledImage.named("ChooserIcon")
    private static var duration: Double { Double(frames.count) / fps }

    var body: some View {
        content
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .onAppear {
                guard plays, !reduceMotion, !Self.frames.isEmpty else {
                    finished = true
                    return
                }
                start = Date()
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
                    finished = true
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !plays || reduceMotion || Self.frames.isEmpty {
            if let still = Self.still {
                Image(nsImage: still).resizable().interpolation(.high)
            }
        } else if finished, let last = Self.frames.last {
            frameImage(last)
        } else if let start {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                let index = min(max(Int(elapsed * Self.fps), 0), Self.frames.count - 1)
                frameImage(Self.frames[index])
            }
        } else {
            frameImage(Self.frames[0])
        }
    }

    private func frameImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.high)
    }

    /// Reads and decodes all frames at once, so the playback does not stutter.
    private static func loadFrames() -> [CGImage] {
        guard let folder = BundledImage.url(of: "IconAnimation"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return [] }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return names.filter { $0.hasSuffix(".png") }.sorted().compactMap { name in
            guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, options)
        }
    }
}
