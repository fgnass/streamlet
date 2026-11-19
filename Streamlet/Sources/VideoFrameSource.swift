import AppKit
import Combine

/// Gets the pictures of a playing video from the page, for the miniplayer.
/// It runs only while a view needs it and while the page plays a video.
final class VideoFrameSource: ObservableObject {
    /// The latest picture, or nil when there is no video or the video is protected.
    @Published private(set) var frame: NSImage?

    private let playerState: PlayerState
    private var timer: Timer?
    private var isRequesting = false
    private var failures = 0
    private var users = 0
    private var cancellables = Set<AnyCancellable>()

    static let framesPerSecond: Double = 15
    var maxWidth = 480

    init(playerState: PlayerState) {
        self.playerState = playerState
        playerState.$hasVideo
            .combineLatest(playerState.$isPlaying)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.update() }
            .store(in: &cancellables)
    }

    /// A view that shows the video calls `start` when it appears and `stop` when it goes.
    func start() {
        users += 1
        update()
    }

    func stop() {
        users = max(0, users - 1)
        update()
    }

    private func update() {
        let active = users > 0 && playerState.hasVideo
        if active, timer == nil {
            failures = 0
            let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
                self?.request()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            request()
        } else if !active, let timer {
            timer.invalidate()
            self.timer = nil
            frame = nil
        }
    }

    private func request() {
        // A paused video keeps its last picture: no new requests are necessary.
        guard !isRequesting, playerState.isPlaying || frame == nil,
              let control = playerState.webViewControl
        else { return }
        isRequesting = true
        control.videoFrame(maxWidth: maxWidth) { [weak self] image in
            guard let self else { return }
            self.isRequesting = false
            guard self.timer != nil else { return }
            if let image {
                self.failures = 0
                self.frame = image
            } else {
                // A protected video never gives a picture. After some tries, show the cover.
                self.failures += 1
                if self.failures >= 5 { self.frame = nil }
            }
        }
    }
}
