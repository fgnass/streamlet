import AppKit
import Combine
import SwiftUI

/// State of the player at the notch.
final class NotchModel: ObservableObject {
    enum Mode { case idle, hover, moment }

    @Published var mode: Mode = .idle
    @Published var notchSize = CGSize(width: 185, height: 32)
    /// True on a display without a camera housing: Streamlet then draws the notch itself.
    @Published var isSimulated = false
    /// Shows the play or pause symbol for a moment after a click.
    @Published var flashSymbol: String?
    @Published var showsEars = true

    static let compactEar: CGFloat = 44
    static let wideEar: CGFloat = 150
    static let momentHeight: CGFloat = 46

    /// The size of the black shape in the current mode.
    var shapeSize: CGSize {
        switch mode {
        case .idle:
            return CGSize(width: notchSize.width + (showsEars ? Self.compactEar * 2 : 0), height: notchSize.height)
        case .hover:
            return CGSize(width: notchSize.width + Self.wideEar * 2, height: notchSize.height)
        case .moment:
            return CGSize(width: max(notchSize.width + 240, 430), height: notchSize.height + Self.momentHeight)
        }
    }

    var cornerRadius: CGFloat {
        switch mode {
        case .idle: return 10
        case .hover: return 13
        case .moment: return 20
        }
    }
}

/// A rectangle with rounded bottom corners. The top edge touches the screen edge.
struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct NotchView: View {
    @ObservedObject var playerState: PlayerState
    @ObservedObject var model: NotchModel
    weak var delegate: PlayerDelegate?
    let events: NotchEventHandler
    /// False only for rendered previews, which cannot draw AppKit views.
    var receivesEvents = true

    var body: some View {
        let size = model.shapeSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: model.cornerRadius)
                    .fill(Color.black)

                VStack(spacing: 0) {
                    topRow
                        .frame(height: model.notchSize.height)
                    if model.mode == .moment {
                        momentBody
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                    Spacer(minLength: 0)
                }

                // The progress of the track is the bottom edge of the notch.
                VStack {
                    Spacer()
                    ProgressLine(playerState: playerState, height: 2, glow: true, seekable: false)
                        .frame(height: 2)
                        .padding(.horizontal, model.cornerRadius + 2)
                        .opacity(playerState.duration > 0 ? 1 : 0)
                }

                if receivesEvents { NotchEventView(handler: events) }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(NotchShape(radius: model.cornerRadius))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.mode)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.showsEars)
    }

    /// Left and right of the camera housing.
    private var topRow: some View {
        HStack(spacing: 0) {
            leftEar
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
            Color.clear.frame(width: model.notchSize.width)
            rightEar
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .clipped()
    }

    @ViewBuilder
    private var leftEar: some View {
        switch model.mode {
        case .hover:
            HStack(spacing: 8) {
                smallCover
                MarqueeText(text: "\(playerState.currentTrack.title) · \(playerState.currentTrack.artist)",
                            font: .system(size: 12, weight: .semibold))
                    .frame(height: 16)
            }
        default:
            if model.showsEars && model.mode == .idle { smallCover }
        }
    }

    @ViewBuilder
    private var rightEar: some View {
        if let symbol = model.flashSymbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(playerState.palette.accentColor)
                .transition(.scale.combined(with: .opacity))
        } else {
            switch model.mode {
            case .hover:
                Text("\(playerState.currentTimeFormatted) / \(playerState.durationFormatted)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
            default:
                if model.showsEars && model.mode == .idle {
                    LevelBars(playerState: playerState, barCount: 6, barWidth: 2.5, spacing: 2, maxHeight: 14)
                }
            }
        }
    }

    private var smallCover: some View {
        CoverView(playerState: playerState, cornerRadius: 5)
            .frame(width: 20, height: 20)
    }

    /// Shown below the notch for a moment when a new track starts.
    private var momentBody: some View {
        HStack(spacing: 10) {
            CoverView(playerState: playerState, cornerRadius: 6)
                .frame(width: 32, height: 32)
            TrackText(playerState: playerState, titleSize: 13, artistSize: 11)
            Spacer(minLength: 0)
            ServiceBadge(playerState: playerState) { delegate?.openWebPlayer() }
        }
        .padding(.horizontal, 16)
        .frame(height: NotchModel.momentHeight - 6)
    }
}

/// Receives clicks and scroll events on the notch.
final class NotchEventHandler {
    var onClick: () -> Void = {}
    var onScroll: (NSEvent) -> Void = { _ in }
}

struct NotchEventView: NSViewRepresentable {
    let handler: NotchEventHandler

    final class EventView: NSView {
        var handler: NotchEventHandler?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { handler?.onClick() }
        }
        override func scrollWheel(with event: NSEvent) { handler?.onScroll(event) }
    }

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: EventView, context: Context) {
        nsView.handler = handler
    }
}

/// A borderless panel that never takes focus.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // The panel sits on top of the menu bar: do not let AppKit move it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The player at the notch: the progress line along the bottom edge, gestures instead of
/// buttons, and a short display of each new track.
final class NotchController {
    private let playerState: PlayerState
    private weak var delegate: PlayerDelegate?
    private let model = NotchModel()
    private let events = NotchEventHandler()
    private var window: NotchPanel?
    private weak var screen: NSScreen?
    /// The top edge of the shape: the screen edge, or the bottom of the menu bar on a
    /// display without a notch.
    private var topY: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()
    private var observers: [Any] = []
    private var mouseMonitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var momentWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    private var isMouseInside = false

    // Scroll state
    private var seekTarget: TimeInterval?
    private var lastSeekSent = Date.distantPast
    private var seekResetWork: DispatchWorkItem?
    private var swipeAccumulator: CGFloat = 0
    private var lastTrackSwitch = Date.distantPast

    private static let extraWidth: CGFloat = 320
    private static let extraHeight: CGFloat = 60

    init(playerState: PlayerState, delegate: PlayerDelegate) {
        self.playerState = playerState
        self.delegate = delegate

        events.onClick = { [weak self] in self?.handleClick() }
        events.onScroll = { [weak self] event in self?.handleScroll(event) }

        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })

        playerState.$isConnectedToService
            .combineLatest(playerState.$currentTrack)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)

        playerState.$trackChangeCount
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showMoment() }
            .store(in: &cancellables)

        update()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        stopMouseMonitoring()
    }

    // MARK: Settings

    private var isEnabled: Bool { UserDefaults.standard.object(forKey: "notchEnabled") as? Bool ?? true }
    private var showsEars: Bool { UserDefaults.standard.object(forKey: "notchShowsEars") as? Bool ?? true }
    private var showsTrackChanges: Bool { UserDefaults.standard.object(forKey: "notchShowsTrackChange") as? Bool ?? true }
    private var usesDisplaysWithoutNotch: Bool { UserDefaults.standard.bool(forKey: "notchOnDisplaysWithoutNotch") }

    /// The display with a camera housing, or the main display when the user wants the
    /// player there too. On a display without a notch, the shape hangs below the menu bar,
    /// so it never covers menu bar items.
    private func targetScreen() -> (screen: NSScreen, notch: CGSize, simulated: Bool)? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = screen.frame.width - left - right
            if width > 0 {
                return (screen, CGSize(width: width, height: screen.safeAreaInsets.top), false)
            }
        }
        guard usesDisplaysWithoutNotch, let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        // No camera housing: only a small gap between the cover and the level display.
        return (screen, CGSize(width: 12, height: 26), true)
    }

    private func rebuild() {
        window?.orderOut(nil)
        window = nil
        update()
    }

    /// Shows the notch player only while there is a track and a display for it.
    private func update() {
        model.showsEars = showsEars
        guard isEnabled, playerState.hasTrack, let target = targetScreen() else {
            window?.orderOut(nil)
            stopMouseMonitoring()
            return
        }
        model.notchSize = target.notch
        model.isSimulated = target.simulated
        let window = self.window ?? makeWindow()
        let menuBarHeight = max(0, target.screen.frame.maxY - target.screen.visibleFrame.maxY)
        topY = target.screen.frame.maxY - (target.simulated ? menuBarHeight : 0)
        let size = NSSize(width: target.notch.width + Self.extraWidth * 2,
                          height: target.notch.height + Self.extraHeight)
        let frame = NSRect(x: target.screen.frame.midX - size.width / 2,
                           y: topY - size.height,
                           width: size.width, height: size.height)
        if window.frame != frame || screen !== target.screen {
            window.setFrame(frame, display: true)
        }
        screen = target.screen
        if !window.isVisible {
            window.orderFrontRegardless()
        }
        startMouseMonitoring()
    }

    private func makeWindow() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchView(
            playerState: playerState, model: model, delegate: delegate, events: events))
        window = panel
        return panel
    }

    // MARK: Mouse

    private func startMouseMonitoring() {
        guard mouseMonitors.isEmpty else { return }
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { [weak self] _ in
            self?.mouseMoved()
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] event in
            self?.mouseMoved()
            return event
        }) { mouseMonitors.append(local) }
    }

    private func stopMouseMonitoring() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        if isMouseInside { setMouseInside(false) }
    }

    /// The black shape in screen coordinates.
    private var shapeRect: NSRect? {
        guard let screen else { return nil }
        let size = model.shapeSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: topY - size.height,
                      width: size.width, height: size.height)
    }

    private func mouseMoved() {
        guard let rect = shapeRect else { return }
        // The top screen row counts too, so the pointer can rest against the screen edge.
        let inside = rect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if inside != isMouseInside { setMouseInside(inside) }
    }

    private func setMouseInside(_ inside: Bool) {
        isMouseInside = inside
        // Outside the shape, clicks go to the menu bar and the windows below.
        window?.ignoresMouseEvents = !inside
        hoverWork?.cancel()
        if inside {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isMouseInside, self.model.mode == .idle else { return }
                self.model.mode = .hover
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else if model.mode == .hover {
            model.mode = .idle
        }
    }

    // MARK: Gestures

    private func handleClick() {
        playerState.togglePlayPause()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        // The state changes when the page answers. Show the expected result at once.
        flash(playerState.isPlaying ? "pause.fill" : "play.fill")
    }

    private func flash(_ symbol: String) {
        flashWork?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { model.flashSymbol = symbol }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.2)) { self?.model.flashSymbol = nil }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func handleScroll(_ event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if abs(dx) > abs(dy) {
            // Horizontal swipe (or Shift + wheel): next or previous track
            if event.phase == .began || event.phase == .mayBegin { swipeAccumulator = 0 }
            swipeAccumulator += dx
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 60 : 1
            guard abs(swipeAccumulator) >= threshold, Date().timeIntervalSince(lastTrackSwitch) > 0.7 else { return }
            lastTrackSwitch = Date()
            if swipeAccumulator < 0 {
                playerState.next()
                flash("forward.end.fill")
            } else {
                playerState.previous()
                flash("backward.end.fill")
            }
            swipeAccumulator = 0
        } else if dy != 0, playerState.canSeek {
            // Vertical scroll: seek. Trackpads give many small steps, wheels give lines.
            let seconds = event.hasPreciseScrollingDeltas ? Double(dy) * 0.2 : Double(dy) * 5
            let base = seekTarget ?? playerState.currentTime
            let target = min(max(base - seconds, 0), playerState.duration)
            seekTarget = target
            if Date().timeIntervalSince(lastSeekSent) > 0.1 {
                lastSeekSent = Date()
                playerState.seek(to: target)
            }
            seekResetWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let target = self.seekTarget else { return }
                self.playerState.seek(to: target)
                self.seekTarget = nil
            }
            seekResetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    // MARK: Track change

    private func showMoment() {
        guard showsTrackChanges, playerState.hasTrack, window?.isVisible == true else { return }
        momentWork?.cancel()
        model.mode = .moment
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.mode == .moment else { return }
            self.model.mode = self.isMouseInside ? .hover : .idle
        }
        momentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}
