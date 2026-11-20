import SwiftUI
import AppKit
import Combine

/// Commands the app can send to the web player.
enum PlayerCommand {
    /// `isPlaying` is the state the app saw last. The page uses it only when it cannot read the real state.
    case playPause(isPlaying: Bool)
    case pause
    case next
    case previous
    case seek(TimeInterval)
    case shuffle
    case repeatMode
    case like
}

// Protocol for controlling web-based playback via JavaScript
protocol WebViewControl: AnyObject {
    func send(_ command: PlayerCommand)
    /// The current picture of the playing video, or nil when there is none.
    func videoFrame(maxWidth: Int, completion: @escaping (NSImage?) -> Void)
}

class PlayerState: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    /// 0 means unknown, for example before a track loads or for a live stream.
    @Published var duration: TimeInterval = 0
    @Published var volume: Double = 0.7
    /// nil: the service has no shuffle control that Streamlet can operate.
    @Published var isShuffle: Bool? = nil
    /// nil: the service has no repeat control that Streamlet can operate.
    @Published var repeatMode: RepeatMode? = nil
    /// nil: the service has no like control that Streamlet can operate.
    @Published var isLiked: Bool? = nil
    @Published var dataSource: DataSource = .mock
    @Published var isConnectedToService: Bool = false
    @Published var isShowingServiceChooserOverlay: Bool = false
    @Published var serviceFaviconURL: String? = nil {
        didSet {
            if serviceFaviconURL != oldValue { loadServiceIcon() }
        }
    }
    /// True when the playing element is a video with a picture, or when a video plays beside it.
    @Published var hasVideo: Bool = false
    /// The top row of pixels of the service page. The title bar of the web player shows it, stretched.
    @Published var pageEdge: NSImage? = nil

    /// The cover of the current track, loaded once for all views.
    @Published private(set) var artwork: NSImage?
    /// Accent colors from the cover, or from the service icon when the cover has no color.
    @Published private(set) var palette: Palette = .fallback
    @Published private(set) var serviceIcon: NSImage?
    /// Goes up by one for each new track. Views use it to show a track change.
    @Published private(set) var trackChangeCount = 0

    private var artworkPalette: Palette?
    private var servicePalette: Palette?
    private var artworkTask: URLSessionDataTask?
    private var serviceIconTask: URLSessionDataTask?

    enum DataSource: Equatable {
        case mock
        case webService(url: String)
    }

    enum RepeatMode: String {
        case none, one, all
    }

    /// Longest time value accepted from a page (one week). Larger values are not real tracks.
    static let maxTime: TimeInterval = 7 * 24 * 3600
    private static let maxTextLength = 500
    private static let lastServiceKey = "lastServiceURL"

    // Reference to webView for controlling playback
    weak var webViewControl: WebViewControl?

    static let emptyTrack = Track(title: "No Track", artist: "No Artist", album: "No Album", albumArt: nil)

    @Published var currentTrack = PlayerState.emptyTrack {
        didSet {
            if currentTrack.albumArt != oldValue.albumArt { loadArtwork() }
        }
    }

    /// True when a real track is loaded (not the placeholder).
    var hasTrack: Bool {
        isConnectedToService && currentTrack != Self.emptyTrack
    }

    /// The name of the open service, for example "SoundCloud".
    var serviceName: String? {
        if case .webService(let url) = dataSource { return KnownService.name(for: url) }
        return nil
    }

    /// Played part of the track in 0…1. Unknown or invalid values give 0, never NaN.
    var progress: Double {
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    /// The service that was open when the app quit last, if any.
    static var lastServiceURL: String? {
        UserDefaults.standard.string(forKey: lastServiceKey)
    }

    func togglePlayPause() {
        guard isConnectedToService else { return }
        webViewControl?.send(.playPause(isPlaying: isPlaying))
    }

    func previous() {
        guard isConnectedToService else { return }
        webViewControl?.send(.previous)
    }

    func next() {
        guard isConnectedToService else { return }
        webViewControl?.send(.next)
    }

    func toggleShuffle() {
        guard isConnectedToService, isShuffle != nil else { return }
        webViewControl?.send(.shuffle)
    }

    func toggleRepeat() {
        guard isConnectedToService, repeatMode != nil else { return }
        webViewControl?.send(.repeatMode)
    }

    func toggleLike() {
        guard isConnectedToService, isLiked != nil else { return }
        webViewControl?.send(.like)
    }

    /// True when the duration is known, so a position in the track can be chosen.
    var canSeek: Bool {
        isConnectedToService && duration > 0
    }

    func seek(to time: TimeInterval) {
        guard canSeek, time.isFinite else { return }
        webViewControl?.send(.seek(min(max(0, time), duration)))
    }

    var currentTimeFormatted: String {
        Self.formatTime(currentTime)
    }

    var durationFormatted: String {
        duration > 0 ? Self.formatTime(duration) : "--:--"
    }

    static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "--:--" }
        let total = Int(min(max(0, time), maxTime))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Validation of values from web content

    /// A time value from a page, or nil when it is not a finite number in the accepted range.
    static func validTime(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber else { return nil }
        let time = number.doubleValue
        guard time.isFinite, time >= 0, time <= maxTime else { return nil }
        return time
    }

    static func validText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTextLength))
    }

    /// Artwork must be a remote http(s) URL. Other schemes (file, data, …) are ignored.
    static func validArtworkURL(_ value: Any?) -> String? {
        guard let text = value as? String, text.count <= 4096,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return text
    }

    // Update from external media session
    func updateFromMediaSession(_ data: [String: Any]) {
        if data["reset"] != nil {
            resetPlayback()
            return
        }

        var didChangeTrack = false
        if let title = Self.validText(data["title"]) {
            let artist = Self.validText(data["artist"]) ?? "Unknown Artist"
            let album = Self.validText(data["album"]) ?? "Unknown Album"
            let artwork = Self.validArtworkURL(data["artwork"])
            didChangeTrack = (title != currentTrack.title) || (artist != currentTrack.artist)
            withAnimation(.easeInOut(duration: 0.3)) {
                currentTrack = Track(
                    title: title,
                    artist: artist,
                    album: album,
                    albumArt: artwork
                )
            }
        }

        if didChangeTrack { trackChangeCount += 1 }

        if let hasVideo = data["video"] as? Bool {
            self.hasVideo = hasVideo
        }

        if let isPlaying = data["isPlaying"] as? Bool {
            self.isPlaying = isPlaying
        }

        if let currentTime = Self.validTime(data["currentTime"]) {
            self.currentTime = currentTime
        } else if didChangeTrack {
            self.currentTime = 0
        }

        if let duration = Self.validTime(data["duration"]) {
            self.duration = duration
        } else if didChangeTrack {
            self.duration = 0
        }

        if let controls = data["controls"] as? [String: Any] {
            isShuffle = controls["shuffle"] as? Bool
            repeatMode = (controls["repeat"] as? String).flatMap(RepeatMode.init(rawValue:))
            isLiked = controls["like"] as? Bool
        }
    }

    /// Clears everything that belongs to the page that was open before.
    private func resetPlayback() {
        currentTrack = Self.emptyTrack
        isPlaying = false
        currentTime = 0
        duration = 0
        isShuffle = nil
        repeatMode = nil
        isLiked = nil
        hasVideo = false
    }

    #if DEBUG
    /// Sets a cover directly, for rendered previews.
    func setPreviewArtwork(_ image: NSImage) {
        artwork = image
        artworkPalette = Palette.from(image)
        updatePalette()
    }
    #endif

    // MARK: - Images and colors

    private func loadArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        let path = currentTrack.albumArt
        artwork = nil
        artworkPalette = nil
        updatePalette()
        guard let url = Self.remoteURL(path) else { return }
        artworkTask = Self.loadImage(url, trimBorders: true) { [weak self] image, palette in
            guard let self, self.currentTrack.albumArt == path else { return }
            self.artwork = image
            self.artworkPalette = palette
            self.updatePalette()
        }
    }

    private func loadServiceIcon() {
        serviceIconTask?.cancel()
        serviceIconTask = nil
        let path = serviceFaviconURL
        serviceIcon = nil
        servicePalette = nil
        updatePalette()
        guard let url = Self.remoteURL(path) else { return }
        serviceIconTask = Self.loadImage(url) { [weak self] image, palette in
            guard let self, self.serviceFaviconURL == path else { return }
            self.serviceIcon = image
            self.servicePalette = palette
            self.updatePalette()
        }
    }

    private func updatePalette() {
        let next = artworkPalette ?? servicePalette ?? .fallback
        if next != palette {
            withAnimation(.easeInOut(duration: 0.4)) { palette = next }
        }
    }

    /// Some services pad covers with thin white or near-white edges. Remove such edges:
    /// lines that are almost completely light, at most 5% of the size per side.
    nonisolated private static func trimmingLightBorders(of image: NSImage) -> NSImage {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return image }
        let width = cg.width, height = cg.height
        guard width >= 32, height >= 32,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return image }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        func isLight(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return min(bytes[i], bytes[i + 1], bytes[i + 2]) > 225
        }
        func columnIsBorder(_ x: Int) -> Bool {
            var light = 0
            for y in 0..<height where isLight(x, y) { light += 1 }
            return Double(light) >= Double(height) * 0.97
        }
        func rowIsBorder(_ y: Int) -> Bool {
            var light = 0
            for x in 0..<width where isLight(x, y) { light += 1 }
            return Double(light) >= Double(width) * 0.97
        }

        let maxX = width / 20, maxY = height / 20
        var left = 0, right = 0, top = 0, bottom = 0
        while left < maxX, columnIsBorder(left) { left += 1 }
        while right < maxX, columnIsBorder(width - 1 - right) { right += 1 }
        // The bitmap's first row is the top of the image.
        while top < maxY, rowIsBorder(top) { top += 1 }
        while bottom < maxY, rowIsBorder(height - 1 - bottom) { bottom += 1 }
        // A side that hits the limit is part of a light cover, not a border: keep it.
        if left == maxX { left = 0 }
        if right == maxX { right = 0 }
        if top == maxY { top = 0 }
        if bottom == maxY { bottom = 0 }
        guard left + right + top + bottom > 0,
              let cropped = cg.cropping(to: CGRect(x: left, y: top, width: width - left - right,
                                                   height: height - top - bottom))
        else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    /// Images come from web pages: only remote http(s) URLs, never local files.
    private static func remoteURL(_ path: String?) -> URL? {
        guard let path, let url = URL(string: path),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    /// Loads an image and finds its colors off the main thread. Calls back on the main thread.
    private static func loadImage(_ url: URL, trimBorders: Bool = false, completion: @escaping (NSImage?, Palette?) -> Void) -> URLSessionDataTask {
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            var image = data.flatMap { NSImage(data: $0) }
            if trimBorders, let loaded = image { image = Self.trimmingLightBorders(of: loaded) }
            let palette = image.flatMap { Palette.from($0) }
            DispatchQueue.main.async { completion(image, palette) }
        }
        task.resume()
        return task
    }

    func connectToService(url: String) {
        resetPlayback()
        dataSource = .webService(url: url)
        isConnectedToService = true
        UserDefaults.standard.set(url, forKey: Self.lastServiceKey)
        // Favicon URL will be extracted from DOM when page loads
    }

    /// Some services move to a regional host after sign-in, for example from
    /// music.amazon.com to music.amazon.de. The sign-in then belongs to the regional host.
    /// Remember that host, so the next launch opens the page where the user is signed in.
    /// The page that is open now stays as it is.
    func noteServiceLocation(_ url: URL) {
        guard case .webService(let current) = dataSource,
              let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased(),
              let stored = Self.lastServiceURL ?? Optional(current),
              let storedHost = URL(string: stored)?.host?.lowercased(), storedHost != host,
              // Only a change of the country domain counts. Sign-in pages and other
              // subdomains of the service (secure.…, accounts.…) do not.
              Self.hostStem(host) == Self.hostStem(storedHost)
        else { return }
        UserDefaults.standard.set("https://\(host)", forKey: Self.lastServiceKey)
    }

    /// The host without its top-level domain: "music.amazon.co.uk" -> "music.amazon".
    private static func hostStem(_ host: String) -> String {
        var parts = host.split(separator: ".").map(String.init)
        guard parts.count > 1 else { return host }
        parts.removeLast()
        if parts.count > 1, ["co", "com"].contains(parts.last!) { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    func disconnectFromService() {
        dataSource = .mock
        isConnectedToService = false
        serviceFaviconURL = nil
        resetPlayback()
        UserDefaults.standard.removeObject(forKey: Self.lastServiceKey)
    }
}

struct Track: Equatable {
    let title: String
    let artist: String
    let album: String
    let albumArt: String?

    static func == (lhs: Track, rhs: Track) -> Bool {
        return lhs.title == rhs.title && lhs.artist == rhs.artist
    }
}
