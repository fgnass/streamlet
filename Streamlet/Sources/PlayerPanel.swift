import AppKit
import SwiftUI

protocol PlayerDelegate: AnyObject {
    func openWebPlayer()
    func toggleMiniPlayer()
    func openSettings()
}

/// The player that opens below the menu bar item: a dark panel without an arrow.
struct PlayerPanelView: View {
    @ObservedObject var playerState: PlayerState
    weak var delegate: PlayerDelegate?
    @AppStorage("showMiniPlayer") private var showMiniPlayer = false

    static let width: CGFloat = 300
    private let padding: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { delegate?.openWebPlayer() }) {
                CoverView(playerState: playerState, cornerRadius: 9)
                    .frame(width: Self.width - padding * 2, height: Self.width - padding * 2)
            }
            .buttonStyle(.plain)
            .help("Open web player")

            HStack(alignment: .top, spacing: 10) {
                TrackText(playerState: playerState, titleSize: 16, artistSize: 13)
                Spacer(minLength: 0)
                ServiceBadge(playerState: playerState) { delegate?.openWebPlayer() }
            }
            .padding(.top, 14)
            .padding(.bottom, 8)

            ProgressLine(playerState: playerState, height: 3)
                .frame(height: 12)
                .opacity(playerState.canSeek ? 1 : 0.4)
            TimeRow(playerState: playerState)
                .padding(.top, 2)

            HStack(spacing: 4) {
                AccentPlayButton(playerState: playerState, size: 40)
                    .padding(.trailing, 4)
                IconButton(systemName: "backward.end.fill", size: 15, help: "Previous") { playerState.previous() }
                IconButton(systemName: "forward.end.fill", size: 15, help: "Next") { playerState.next() }
                Spacer(minLength: 0)
                SecondaryControls(playerState: playerState)
                IconButton(
                    systemName: "pip",
                    size: 14,
                    isDim: true,
                    isActive: showMiniPlayer,
                    help: showMiniPlayer ? "Hide miniplayer" : "Show miniplayer",
                    tint: playerState.palette.accentColor
                ) { delegate?.toggleMiniPlayer() }
            }
            .padding(.top, 10)
        }
        .padding(padding)
        .frame(width: Self.width)
        .background(
            ZStack {
                Theme.panel
                // Soft glow in the accent color below the cover
                Ellipse()
                    .fill(playerState.palette.accentColor)
                    .frame(width: 220, height: 90)
                    .blur(radius: 55)
                    .opacity(0.22)
                    .offset(y: 100)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

/// Shuffle, repeat and like. Each one shows only when the service has the control.
struct SecondaryControls: View {
    @ObservedObject var playerState: PlayerState

    var body: some View {
        HStack(spacing: 2) {
            if let isShuffle = playerState.isShuffle {
                IconButton(systemName: "shuffle", size: 13, isDim: true, isActive: isShuffle,
                           help: "Shuffle", tint: playerState.palette.accentColor) { playerState.toggleShuffle() }
            }
            if let repeatMode = playerState.repeatMode {
                IconButton(systemName: repeatMode == .one ? "repeat.1" : "repeat", size: 13, isDim: true,
                           isActive: repeatMode != .none, help: "Repeat",
                           tint: playerState.palette.accentColor) { playerState.toggleRepeat() }
            }
            if let isLiked = playerState.isLiked {
                IconButton(systemName: isLiked ? "heart.fill" : "heart", size: 13, isDim: true,
                           isActive: isLiked, help: "Like",
                           tint: playerState.palette.accentColor) { playerState.toggleLike() }
            }
        }
    }
}

/// A borderless panel that can take key status, so Escape closes it.
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Shows the player panel below a menu bar item and closes it on a click outside.
final class PlayerPanelController {
    private let panel: KeyablePanel
    private let hostingView: NSHostingView<PlayerPanelView>
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// The window of the menu bar item. Clicks there toggle the panel, so they do not close it.
    private weak var anchorWindow: NSWindow?

    var isShown: Bool { panel.isVisible }

    init(playerState: PlayerState, delegate: PlayerDelegate) {
        hostingView = NSHostingView(rootView: PlayerPanelView(playerState: playerState, delegate: delegate))
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: PlayerPanelView.width, height: 460),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hostingView
        panel.onCancel = { [weak self] in self?.close() }
    }

    /// Opens the panel below `anchor`, a rectangle in screen coordinates.
    func show(below anchor: NSRect, anchorWindow: NSWindow?) {
        self.anchorWindow = anchorWindow
        let screen = anchorWindow?.screen ?? NSScreen.main
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        var x = anchor.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        let top = (screen?.visibleFrame.maxY ?? anchor.minY) - 5
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // Nothing has focus when the panel opens. With keyboard navigation on, the focus
        // ring then appears only after Tab.
        panel.makeFirstResponder(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        panel.invalidateShadow()
        startMonitoring()
    }

    func close() {
        guard panel.isVisible else { return }
        stopMonitoring()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    private func startMonitoring() {
        stopMonitoring()
        // Clicks in other apps
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        // Clicks in Streamlet's other windows. The menu bar item handles its own clicks.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // A right-click on the menu bar item opens its context menu: close the panel too.
            if event.window !== self.panel && (event.window !== self.anchorWindow || event.type == .rightMouseDown) {
                self.close()
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
