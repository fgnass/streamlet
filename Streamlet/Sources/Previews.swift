#if DEBUG
import AppKit
import SwiftUI

/// Renders the player views with a sample track to PNG files and quits.
/// Start with: Streamlet --render-previews <folder>
@MainActor
enum PreviewRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-previews"), index + 1 < args.count else { return }
        let folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Optional track for the renders:
        //   --preview-cover <image> --preview-title <t> --preview-artist <a> --preview-service <url>
        // With a cover, only the track-dependent views are rendered.
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let customCover = option("--preview-cover").flatMap { NSImage(contentsOfFile: $0) }

        let state = PlayerState()
        state.connectToService(url: option("--preview-service") ?? "https://soundcloud.com")
        state.updateFromMediaSession([
            "title": option("--preview-title") ?? "Low Tide Radio",
            "artist": option("--preview-artist") ?? "Marla Venn",
            "isPlaying": true, "currentTime": 71, "duration": 214,
        ])
        state.setPreviewArtwork(customCover ?? sampleCover())
        for (name, color) in [("accent", state.palette.accent), ("accent2", state.palette.accent2)] {
            if let c = color.usingColorSpace(.sRGB) {
                print(String(format: "Palette %@ #%02X%02X%02X", name,
                             Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255))))
            }
        }

        let video = VideoFrameSource(playerState: state)
        let dock = MiniPlayerDock()

        render(PlayerPanelView(playerState: state), "panel", folder)
        for (name, size) in [("mini-cover", CGSize(width: 110, height: 110)),
                             ("mini-slim", CGSize(width: 240, height: 72)),
                             ("mini-strip", CGSize(width: 340, height: 96)),
                             ("mini-large", CGSize(width: 460, height: 220))] {
            render(MiniPlayerView(playerState: state, video: video, dock: dock)
                .frame(width: size.width, height: size.height), name, folder)
        }
        for mode in [NotchModel.Mode.idle, .hover, .moment] {
            let model = NotchModel()
            model.notchSize = CGSize(width: 185, height: 32)
            model.mode = mode
            render(NotchView(playerState: state, model: model, events: NotchEventHandler(), receivesEvents: false)
                .frame(width: 185 + 640, height: 32 + 60)
                .background(Color(white: 0.35)), "notch-\(mode)", folder)
        }
        for (name, content) in [
            ("cast-connecting", CastToastModel.Content(symbol: nil, title: "Connecting to Wohnzimmer…")),
            ("cast-playing", CastToastModel.Content(symbol: "hifispeaker.fill", title: "Playing on Wohnzimmer")),
            ("cast-failed", CastToastModel.Content(symbol: "exclamationmark.triangle.fill", title: "Cannot cast to Wohnzimmer",
                                                   detail: "The device did not start to play.")),
        ] {
            let model = CastToastModel()
            model.content = content
            render(CastToastView(model: model).padding(20).background(Color(white: 0.35)), name, folder)
        }
        if customCover != nil { exit(0) }
        render(ServiceChooserView(playerState: PlayerState()).frame(width: 1000, height: 640), "chooser-swiftui", folder)
        renderDockIcons(folder)
        renderHosted(ServiceChooserView(playerState: PlayerState()), size: CGSize(width: 1000, height: 640), "chooser", folder)
        exit(0)
    }

    /// Dock icons for the known services, from freshly fetched favicons.
    private static func renderDockIcons(_ folder: URL) {
        var favicons: [String: Data] = [:]
        var pending = KnownService.all.count
        for service in KnownService.all {
            Task {
                let suggestion = ServiceSuggestion(name: service.name, url: service.url)
                let data = await ServiceSuggestionsManager.fetchFavicon(for: suggestion)
                await MainActor.run {
                    favicons[service.url] = data
                    pending -= 1
                }
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while pending > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        for (url, iconData) in favicons {
            guard let icon = NSImage(data: iconData), let dock = DockIcon.make(serviceIcon: icon),
                  let tiff = dock.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            let name = "dock-" + (URL(string: url)?.host ?? "service")
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
            print("Rendered \(name)")
        }
    }

    /// Renders through AppKit, for views with AppKit controls (text fields) that
    /// ImageRenderer cannot draw.
    private static func renderHosted<V: View>(_ view: V, size: CGSize, _ name: String, _ folder: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (favicons from the cache, layout) and let the icon
        // animation of the chooser (about 1.8 s) finish before the capture.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
        print("Rendered \(name)")
    }

    private static func render<V: View>(_ view: V, _ name: String, _ folder: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { print("Could not render \(name)"); return }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
        print("Rendered \(name)")
    }

    private static func sampleCover() -> NSImage {
        let size = NSSize(width: 300, height: 300)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.16, green: 0.06, blue: 0.18, alpha: 1).setFill()
            rect.fill()
            let blobs: [(NSColor, CGPoint, CGFloat)] = [
                (NSColor(srgbRed: 1.0, green: 0.62, blue: 0.3, alpha: 1), CGPoint(x: 90, y: 200), 120),
                (NSColor(srgbRed: 0.8, green: 0.24, blue: 0.48, alpha: 1), CGPoint(x: 220, y: 90), 140),
            ]
            for (color, center, radius) in blobs {
                let gradient = NSGradient(colors: [color, color.withAlphaComponent(0)])
                gradient?.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
            }
            return true
        }
    }
}
#endif
