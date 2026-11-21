import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

protocol PopoverDelegate: AnyObject {
    func togglePopover()
    func openSettings()
    func openWebPlayer()
    func toggleMiniPlayer()
    func changeService()
    func clearServiceData()
    func quitApp()
}

struct MenuBarControlsView: View {
    @ObservedObject var playerState: PlayerState
    @AppStorage("enableMenuBarPlayerControls") private var enableMenuBarPlayerControls = false
    @State private var hoveredButton: String? = nil
    weak var popoverDelegate: PopoverDelegate?

    var body: some View {
        if enableMenuBarPlayerControls {
            HStack(spacing: 4) {
                // Previous button
                Button(action: { 
                    hoveredButton = nil
                    playerState.previous() 
                }) {
                    ZStack {
                        if hoveredButton == "prev" {
                            Circle()
                                .fill(Color.primary.opacity(0.2))
                                .frame(width: 20, height: 20)
                        }
                        
                        Image(systemName: "backward.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Circle())
                .buttonStyle(PlainButtonStyle())
                .onHover { isHovered in
                    hoveredButton = isHovered ? "prev" : nil
                }

                // Play/Pause button
                Button(action: { 
                    hoveredButton = nil
                    playerState.togglePlayPause() 
                }) {
                    ZStack {
                        if hoveredButton == "play" {
                            Circle()
                                .fill(Color.primary.opacity(0.2))
                                .frame(width: 20, height: 20)
                        }

                        Image(
                            systemName: playerState.isPlaying ? "pause.fill" : "play.fill"
                        )
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .offset(x: playerState.isPlaying ? 0 : 0.5)
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Circle())
                .buttonStyle(PlainButtonStyle())
                .onHover { isHovered in
                    hoveredButton = isHovered ? "play" : nil
                }

                // Next button
                Button(action: { 
                    hoveredButton = nil
                    playerState.next() 
                }) {
                    ZStack {
                        if hoveredButton == "next" {
                            Circle()
                                .fill(Color.primary.opacity(0.2))
                                .frame(width: 20, height: 20)
                        }
                        
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Circle())
                .buttonStyle(PlainButtonStyle())
                .onHover { isHovered in
                    hoveredButton = isHovered ? "next" : nil
                }
            }
            .frame(height: 22)
        } else {
            EmptyView()
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var playerState: PlayerState
    let statusItem: NSStatusItem
    weak var popoverDelegate: PopoverDelegate?
    @AppStorage("enableMenuBarItem") private var enableMenuBarItem = true
    @AppStorage("menuBarIcon") private var menuBarIcon = "auto"
    @AppStorage("menuBarShowsProgress") private var menuBarShowsProgress = true
    @AppStorage("songInfoInMenuBar") private var songInfoInMenuBar = "always"
    @AppStorage("songInfoDetails") private var songInfoDetails = "song"
    @AppStorage("songInfoWidth") private var songInfoWidth: Double = 100
    @AppStorage("fixedSongInfoWidth") private var fixedSongInfoWidth = false
    @State private var widthUpdateTask: DispatchWorkItem?

    private var shouldShowMenuBar: Bool {
        return enableMenuBarItem
    }

    private var shouldShowIconSlot: Bool {
        menuBarIcon != "hidden"
    }

    private var shouldShowProgress: Bool {
        menuBarShowsProgress && playerState.hasTrack && playerState.duration > 0
    }

    static let progressWidth: CGFloat = 30

    private var shouldShowSongInfo: Bool {
        guard enableMenuBarItem else { return false }

        switch songInfoInMenuBar {
        case "always":
            return true
        case "whenPlaying":
            return playerState.isPlaying
        case "never":
            return false
        default:
            return false
        }
    }

    private var songInfoText: String {
        guard shouldShowSongInfo else { return "" }

        let track = playerState.currentTrack

        switch songInfoDetails {
        case "song":
            return track.title
        case "artist":
            return track.artist
        case "artistAndTrack":
            if !track.artist.isEmpty && !track.title.isEmpty {
                return "\(track.artist) - \(track.title)"
            } else if !track.artist.isEmpty {
                return track.artist
            } else {
                return track.title
            }
        default:
            return track.title
        }
    }

    private var calculatedWidth: CGFloat {
        if !shouldShowMenuBar {
            return 0
        }

        var width: CGFloat = 0

        // Single slot for the icon
        if shouldShowIconSlot {
            width += 20
        }

        // Add spacing between icon and text if both exist
        if shouldShowIconSlot && shouldShowSongInfo && !songInfoText.isEmpty {
            width += 8
        }

        // Add space for song info if enabled
        if shouldShowSongInfo && !songInfoText.isEmpty {
            if fixedSongInfoWidth {
                // Fixed width: always use the slider value
                width += CGFloat(songInfoWidth)
            } else {
                // Dynamic width: calculate actual text size
                let attributes = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 13)]
                let textSize = (songInfoText as NSString).size(withAttributes: attributes)

                // Always use actual text width for dynamic mode
                width += textSize.width
            }
        }


        if shouldShowProgress {
            width += 8 + Self.progressWidth
        }

        return width
    }

    var body: some View {
        if shouldShowMenuBar {
            HStack(spacing: 0) {
                Spacer()
                
                // Icon and song info display (non-clickable since clicks are handled by NSStatusItem)
                if shouldShowIconSlot || (shouldShowSongInfo && !songInfoText.isEmpty) {
                    HStack(spacing: 0) {
                        // Single slot: the icon
                        if shouldShowIconSlot {
                            Group {
                                switch menuBarIcon {
                                case "albumArt":
                                    CoverView(playerState: playerState, cornerRadius: 3)
                                        .frame(width: 16, height: 16)
                                case "appIcon":
                                    StreamletMenuBarIcon()
                                case "serviceIcon":
                                    // Show service favicon if connected, otherwise app icon
                                    if let faviconURL = playerState.serviceFaviconURL, playerState.isConnectedToService {
                                        AsyncImage(url: URL(string: faviconURL)) { image in
                                            image
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 16, height: 16)
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        } placeholder: {
                                            StreamletMenuBarIcon()
                                        }
                                    } else {
                                        StreamletMenuBarIcon()
                                    }
                                default:
                                    // Automatic: level bars while music plays, otherwise the app icon.
                                    if playerState.isPlaying && playerState.hasTrack {
                                        LevelBars(playerState: playerState, barCount: 4, barWidth: 2,
                                                  spacing: 1.5, maxHeight: 13, monochrome: true)
                                    } else {
                                        StreamletMenuBarIcon()
                                    }
                                }
                            }
                            .frame(width: 20)
                        }

                        // Song info text
                        if shouldShowSongInfo && !songInfoText.isEmpty {
                            if shouldShowIconSlot {
                                Color.clear.frame(width: 8)
                            }

                            Text(songInfoText)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .if(!fixedSongInfoWidth) { view in
                                    // Dynamic width - natural sizing
                                    view
                                }
                                .if(fixedSongInfoWidth) { view in
                                    // Fixed width
                                    view.frame(width: CGFloat(songInfoWidth), alignment: .leading)
                                }
                        }

                        if shouldShowProgress {
                            Color.clear.frame(width: 8)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.25))
                                Capsule()
                                    .fill(playerState.palette.accentColor)
                                    .frame(width: Self.progressWidth * playerState.progress)
                            }
                            .frame(width: Self.progressWidth, height: 2)
                        }
                    }
                }
                
                Spacer()
            }
            .frame(height: 22)
            .onAppear {
                updateStatusItemWidth(calculatedWidth)
            }
            .onChange(of: calculatedWidth) { newWidth in
                updateStatusItemWidth(newWidth)
            }
            .onChange(of: songInfoText) { _ in
                // Update width when track changes (if not using fixed width)
                if !fixedSongInfoWidth {
                    updateStatusItemWidth(calculatedWidth)
                }
            }
            .onChange(of: playerState.currentTrack.title) { _ in
                // Update width when track title changes
                if !fixedSongInfoWidth {
                    updateStatusItemWidth(calculatedWidth)
                }
            }
            .onChange(of: playerState.currentTrack.artist) { _ in
                // Update width when track artist changes
                if !fixedSongInfoWidth {
                    updateStatusItemWidth(calculatedWidth)
                }
            }
        } else {
            EmptyView()
                .frame(width: 0, height: 22)
                .onAppear {
                    updateStatusItemWidth(0)
                }
        }
    }

    private func updateStatusItemWidth(_ width: CGFloat) {
        if shouldShowMenuBar {
            statusItem.length = width
        } else {
            statusItem.length = 0
        }
    }
}

/// The S of the app icon, flat and in the color of the menu bar text.
struct StreamletMenuBarIcon: View {
    var body: some View {
        StreamletLogoShape()
            .fill(Color.primary, style: FillStyle(eoFill: true))
            .frame(width: 16, height: 16)
    }
}

/// The S of the app icon as a flat shape with the play triangle as a hole.
/// The outline is point-symmetric: the second half is the first half rotated by 180°.
/// Coordinates are in a 100 × 100 square. Fill it with the even-odd rule.
struct StreamletLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x / 100 * side, y: origin.y + y / 100 * side)
        }
        var path = Path()
        path.move(to: p(62, 31))
        path.addCurve(to: p(87, 21), control1: p(70.97, 30.28), control2: p(82.05, 25.95))
        path.addCurve(to: p(80, 8), control1: p(89.83, 18.17), control2: p(85.75, 9.72))
        path.addCurve(to: p(13, 40), control1: p(43.6, -2.92), control2: p(13, 13))
        path.addCurve(to: p(38, 69), control1: p(13, 56), control2: p(25.23, 63.25))
        path.addCurve(to: p(13, 79), control1: p(29.03, 69.72), control2: p(17.95, 74.05))
        path.addCurve(to: p(20, 92), control1: p(10.17, 81.83), control2: p(14.25, 90.28))
        path.addCurve(to: p(87, 60), control1: p(56.4, 102.92), control2: p(87, 87))
        path.addCurve(to: p(62, 31), control1: p(87, 44), control2: p(74.77, 36.75))
        path.closeSubpath()
        // The play triangle, a hole with slightly rounded corners
        path.move(to: p(41.5, 36.5))
        path.addQuadCurve(to: p(43.57, 35.41), control: p(41.5, 34))
        path.addLine(to: p(62.93, 48.59))
        path.addQuadCurve(to: p(62.93, 51.41), control: p(65, 50))
        path.addLine(to: p(43.57, 64.59))
        path.addQuadCurve(to: p(41.5, 63.5), control: p(41.5, 66))
        path.closeSubpath()
        return path
    }
}
