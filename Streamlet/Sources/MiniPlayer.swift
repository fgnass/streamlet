import AppKit
import Combine
import SwiftUI

/// Where the miniplayer is docked. A docked miniplayer hides at the screen edge and
/// leaves only a narrow tab in the accent color.
final class MiniPlayerDock: ObservableObject {
    enum Edge { case none, left, right }
    @Published var edge: Edge = .none
    @Published var isCollapsed = false
}

/// The miniplayer has no style setting. Its layout follows its size.
enum MiniPlayerLayout: Equatable {
    case cover, slim, strip, large

    init(size: CGSize) {
        if size.width <= 170 {
            self = .cover
        } else if size.height >= 170 {
            self = .large
        } else if size.width <= 270 {
            self = .slim
        } else {
            self = .strip
        }
    }
}

struct MiniPlayerView: View {
    @ObservedObject var playerState: PlayerState
    @ObservedObject var video: VideoFrameSource
    @ObservedObject var dock: MiniPlayerDock
    weak var delegate: PlayerDelegate?
    var onHover: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}

    @AppStorage("miniPlayerShowsVideo") private var showsVideo = true
    @State private var isHovering = false

    static let tabWidth: CGFloat = 12

    private var videoFrame: NSImage? { showsVideo ? video.frame : nil }

    var body: some View {
        GeometryReader { geometry in
            let layout = MiniPlayerLayout(size: geometry.size)
            ZStack {
                Theme.panel
                content(layout: layout, size: geometry.size)
                if layout != .large || videoFrame != nil {
                    VStack {
                        Spacer()
                        ProgressLine(playerState: playerState, height: layout == .cover ? 3 : 2, glow: false, rounded: false)
                            .frame(height: 6, alignment: .bottom)
                    }
                }
                if isHovering && !dock.isCollapsed {
                    windowButtons
                }
                dockTab
            }
        }
        // The window has an invisible title bar: use its area too.
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            onHover(hovering)
        }
        .contextMenu {
            Button("Open Web Player") { delegate?.openWebPlayer() }
            Toggle("Show Video", isOn: $showsVideo)
            Divider()
            Button("Hide Miniplayer") { onClose() }
        }
    }

    @ViewBuilder
    private func content(layout: MiniPlayerLayout, size: CGSize) -> some View {
        switch layout {
        case .cover:
            ZStack {
                CoverView(playerState: playerState, cornerRadius: 0, videoFrame: videoFrame)
                if isHovering {
                    Color.black.opacity(0.35)
                    AccentPlayButton(playerState: playerState, size: min(40, size.width * 0.38))
                }
            }
        case .slim:
            HStack(spacing: 10) {
                CoverView(playerState: playerState, cornerRadius: 6, videoFrame: videoFrame)
                    .frame(width: size.height - 20, height: size.height - 20)
                TrackText(playerState: playerState, titleSize: 13, artistSize: 11)
                Spacer(minLength: 0)
                AccentPlayButton(playerState: playerState, size: 30)
            }
            .padding(10)
        case .strip:
            HStack(spacing: 12) {
                CoverView(playerState: playerState, cornerRadius: 7, videoFrame: videoFrame)
                    .frame(width: size.height - 20, height: size.height - 20)
                TrackText(playerState: playerState, titleSize: 14, artistSize: 12)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    IconButton(systemName: "backward.end.fill", size: 13, help: "Previous") { playerState.previous() }
                    AccentPlayButton(playerState: playerState, size: 34)
                    IconButton(systemName: "forward.end.fill", size: 13, help: "Next") { playerState.next() }
                }
            }
            .padding(10)
        case .large:
            if let videoFrame {
                VStack(spacing: 0) {
                    CoverView(playerState: playerState, cornerRadius: 0, videoFrame: videoFrame)
                        .frame(maxHeight: .infinity)
                    HStack(spacing: 10) {
                        AccentPlayButton(playerState: playerState, size: 30)
                        TrackText(playerState: playerState, titleSize: 13, artistSize: 11)
                        Spacer(minLength: 0)
                        IconButton(systemName: "forward.end.fill", size: 12, help: "Next") { playerState.next() }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 52)
                }
            } else {
                HStack(spacing: 16) {
                    CoverView(playerState: playerState, cornerRadius: 9)
                        .frame(width: size.height - 28, height: size.height - 28)
                    VStack(alignment: .leading, spacing: 0) {
                        TrackText(playerState: playerState, titleSize: 17, artistSize: 13)
                        ServiceBadge(playerState: playerState) { delegate?.openWebPlayer() }
                            .padding(.top, 8)
                        Spacer(minLength: 6)
                        ProgressLine(playerState: playerState, height: 3)
                            .frame(height: 10)
                        TimeRow(playerState: playerState, fontSize: 10)
                            .padding(.bottom, 6)
                        HStack(spacing: 2) {
                            IconButton(systemName: "backward.end.fill", size: 13, help: "Previous") { playerState.previous() }
                            AccentPlayButton(playerState: playerState, size: 34)
                            IconButton(systemName: "forward.end.fill", size: 13, help: "Next") { playerState.next() }
                            Spacer(minLength: 0)
                            SecondaryControls(playerState: playerState)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    /// Small buttons in the top corner, visible on hover.
    private var windowButtons: some View {
        VStack {
            HStack(spacing: 4) {
                Spacer()
                cornerButton("arrow.up.forward.app", help: "Open web player") { delegate?.openWebPlayer() }
                cornerButton("xmark", help: "Hide miniplayer") { onClose() }
            }
            Spacer()
        }
        .padding(6)
        .transition(.opacity)
    }

    private func cornerButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The narrow tab that stays visible while the miniplayer hides at the screen edge.
    @ViewBuilder
    private var dockTab: some View {
        if dock.isCollapsed && dock.edge != .none {
            HStack(spacing: 0) {
                if dock.edge == .left { Spacer() }
                ZStack {
                    Theme.panel
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [playerState.palette.accentColor, playerState.palette.accent2Color],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 4)
                        .padding(.vertical, 12)
                        .shadow(color: playerState.palette.accentColor.opacity(0.8), radius: 5)
                }
                .frame(width: Self.tabWidth)
                if dock.edge == .right { Spacer() }
            }
            .transition(.opacity)
        }
    }
}

/// The miniplayer window and its docking at the screen edge.
final class MiniPlayerController: NSObject, NSWindowDelegate {
    private let playerState: PlayerState
    private let video: VideoFrameSource
    private let dock = MiniPlayerDock()
    private weak var delegate: PlayerDelegate?
    private var window: NSPanel?
    private var dockCheck: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var isMovingProgrammatically = false
    private var defaultsObserver: Any?

    static let minSize = NSSize(width: 72, height: 72)
    static let maxSize = NSSize(width: 640, height: 400)

    init(playerState: PlayerState, delegate: PlayerDelegate) {
        self.playerState = playerState
        self.video = VideoFrameSource(playerState: playerState)
        self.delegate = delegate
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applySettings() }
        applySettings()
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: "showMiniPlayer") }
    private var dockingEnabled: Bool { UserDefaults.standard.object(forKey: "miniPlayerDocks") as? Bool ?? true }
    private var keepsOnTop: Bool { UserDefaults.standard.object(forKey: "miniPlayerOnTop") as? Bool ?? true }
    private var showsVideo: Bool { UserDefaults.standard.object(forKey: "miniPlayerShowsVideo") as? Bool ?? true }

    private var isApplyingSettings = false

    /// Shows or hides the window to match the settings.
    private func applySettings() {
        // Window changes write to the defaults too: do not run again from inside.
        guard !isApplyingSettings else { return }
        isApplyingSettings = true
        defer { isApplyingSettings = false }
        if isEnabled {
            show()
        } else {
            hide()
        }
        window?.level = keepsOnTop ? .floating : .normal
        updateVideo()
        if !dockingEnabled, dock.edge != .none { undock() }
    }

    private var videoRunning = false
    private func updateVideo() {
        let shouldRun = (window?.isVisible ?? false) && showsVideo
        if shouldRun != videoRunning {
            videoRunning = shouldRun
            shouldRun ? video.start() : video.stop()
        }
        if let window { video.maxWidth = Int(min(640, window.frame.width * 2)) }
    }

    private func show() {
        let window = self.window ?? makeWindow()
        guard !window.isVisible else { return }
        window.orderFrontRegardless()
        updateVideo()
        scheduleDockCheck(after: 0.1)
    }

    private func hide() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        updateVideo()
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Theme.panelNS
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = Self.minSize
        panel.maxSize = Self.maxSize
        panel.delegate = self
        self.window = panel

        let view = MiniPlayerView(
            playerState: playerState,
            video: video,
            dock: dock,
            delegate: delegate,
            onHover: { [weak self] inside in self?.hoverChanged(inside) },
            onClose: { UserDefaults.standard.set(false, forKey: "showMiniPlayer") }
        )
        panel.contentView = NSHostingView(rootView: view)

        if !panel.setFrameUsingName(Self.autosaveName), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 340 - 24, y: visible.minY + 24))
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        return panel
    }

    private static let autosaveName = "StreamletMiniPlayer"

    // MARK: - Docking

    func windowDidMove(_ notification: Notification) {
        guard !isMovingProgrammatically else { return }
        scheduleDockCheck(after: 0.25)
    }

    func windowDidResize(_ notification: Notification) {
        updateVideo()
        guard !isMovingProgrammatically, dock.edge != .none, !dock.isCollapsed, let window, let screen = window.screen else { return }
        // Keep a docked player at its edge while it changes size.
        var frame = window.frame
        frame.origin.x = dock.edge == .right ? screen.frame.maxX - frame.width : screen.frame.minX
        moveProgrammatically(to: frame, animate: false)
    }

    private func scheduleDockCheck(after delay: TimeInterval) {
        dockCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkDock() }
        dockCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// After the user moves the window: dock it when it touches a screen edge.
    private func checkDock() {
        guard let window, window.isVisible, let screen = window.screen else { return }
        // Wait until the drag ends.
        if NSEvent.pressedMouseButtons != 0 {
            scheduleDockCheck(after: 0.2)
            return
        }
        guard dockingEnabled else { return }
        let frame = window.frame
        let screenFrame = screen.frame
        if frame.maxX >= screenFrame.maxX - 1 {
            dock.edge = .right
        } else if frame.minX <= screenFrame.minX + 1 {
            dock.edge = .left
        } else {
            dock.edge = .none
            dock.isCollapsed = false
            return
        }
        collapse()
    }

    private func hoverChanged(_ inside: Bool) {
        guard dock.edge != .none else { return }
        collapseWork?.cancel()
        if inside {
            expand()
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard NSEvent.pressedMouseButtons == 0 else { return }
                self?.collapse()
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }

    private func collapse() {
        guard let window, let screen = window.screen, dock.edge != .none else { return }
        var frame = window.frame
        frame.origin.x = dock.edge == .right
            ? screen.frame.maxX - MiniPlayerView.tabWidth
            : screen.frame.minX - frame.width + MiniPlayerView.tabWidth
        withAnimation(.easeInOut(duration: 0.2)) { dock.isCollapsed = true }
        moveProgrammatically(to: frame, animate: true)
    }

    private func expand() {
        guard let window, let screen = window.screen, dock.edge != .none, dock.isCollapsed else { return }
        var frame = window.frame
        frame.origin.x = dock.edge == .right ? screen.frame.maxX - frame.width : screen.frame.minX
        withAnimation(.easeInOut(duration: 0.15)) { dock.isCollapsed = false }
        moveProgrammatically(to: frame, animate: true)
    }

    private func undock() {
        guard let window, let screen = window.screen else { return }
        var frame = window.frame
        frame.origin.x = dock.edge == .right ? screen.frame.maxX - frame.width - 24 : screen.frame.minX + 24
        dock.edge = .none
        dock.isCollapsed = false
        moveProgrammatically(to: frame, animate: true)
    }

    private func moveProgrammatically(to frame: NSRect, animate: Bool) {
        guard let window else { return }
        isMovingProgrammatically = true
        if animate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                self?.isMovingProgrammatically = false
            })
        } else {
            window.setFrame(frame, display: true)
            isMovingProgrammatically = false
        }
    }
}
