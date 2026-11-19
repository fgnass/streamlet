import AppKit
import SwiftUI

// Building blocks that the player panel, the miniplayer and the notch share.

/// The cover of the current track. Shows the video picture instead when one is given.
struct CoverView: View {
    @ObservedObject var playerState: PlayerState
    var cornerRadius: CGFloat = 8
    var videoFrame: NSImage? = nil

    var body: some View {
        ZStack {
            if let videoFrame {
                Image(nsImage: videoFrame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let artwork = playerState.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                // No cover: a soft gradient in the accent colors
                LinearGradient(
                    colors: [playerState.palette.accent2Color.opacity(0.55), playerState.palette.accentColor.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                )
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: playerState.artwork)
    }
}

/// The round play/pause button in the accent color.
struct AccentPlayButton: View {
    @ObservedObject var playerState: PlayerState
    var size: CGFloat = 40
    @State private var isPressed = false

    var body: some View {
        Button(action: { playerState.togglePlayPause() }) {
            ZStack {
                Circle()
                    .fill(playerState.palette.accentColor)
                    .shadow(color: playerState.palette.accentColor.opacity(0.55), radius: size * 0.25, y: size * 0.1)
                Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundColor(Color(white: 0.07))
                    .offset(x: playerState.isPlaying ? 0 : size * 0.04)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .help(playerState.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(playerState.isPlaying ? "Pause" : "Play")
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A plain icon button with a soft hover background.
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 15
    var isDim = false
    var isActive = false
    var help: String = ""
    var tint: Color = Theme.text
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(isActive ? tint : (isDim ? Theme.secondaryText : Theme.text))
                .opacity(isHovering ? 1 : (isDim && !isActive ? 0.75 : 0.9))
                .frame(width: size * 1.9, height: size * 1.9)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The progress of the track as a thin line in the accent gradient. Click or drag to seek.
struct ProgressLine: View {
    @ObservedObject var playerState: PlayerState
    var height: CGFloat = 3
    var glow = true
    var seekable = true
    var rounded = true

    var body: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: rounded ? height / 2 : 0)
            ZStack(alignment: .leading) {
                shape.fill(Theme.track)
                shape
                    .fill(LinearGradient(
                        colors: [playerState.palette.accent2Color, playerState.palette.accentColor],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * playerState.progress)
                    .shadow(color: glow ? playerState.palette.accentColor.opacity(0.7) : .clear, radius: glow ? 4 : 0)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard seekable, playerState.canSeek, geometry.size.width > 0 else { return }
                        let fraction = min(max(drag.location.x / geometry.size.width, 0), 1)
                        playerState.seek(to: fraction * playerState.duration)
                    }
            )
        }
        .animation(.linear(duration: 0.25), value: playerState.progress)
    }
}

/// Elapsed time on the left, remaining time on the right.
struct TimeRow: View {
    @ObservedObject var playerState: PlayerState
    var fontSize: CGFloat = 11

    var body: some View {
        HStack {
            Text(playerState.currentTimeFormatted)
            Spacer()
            Text(playerState.duration > 0
                 ? "-" + PlayerState.formatTime(playerState.duration - playerState.currentTime)
                 : "--:--")
        }
        .font(.system(size: fontSize, design: .monospaced))
        .foregroundColor(Theme.secondaryText)
    }
}

/// A small label with the service name and a dot in the service color. Opens the web player.
struct ServiceBadge: View {
    @ObservedObject var playerState: PlayerState
    var action: (() -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        if let name = playerState.serviceName {
            Button(action: { action?() }) {
                HStack(spacing: 5) {
                    if let icon = playerState.serviceIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                            .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    } else {
                        Circle()
                            .fill(playerState.palette.accentColor)
                            .frame(width: 7, height: 7)
                    }
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(isHovering ? Theme.text : Theme.secondaryText)
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(isHovering ? 0.11 : 0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Open \(name)")
            .fixedSize()
        }
    }
}

/// Title and artist, left-aligned.
struct TrackText: View {
    @ObservedObject var playerState: PlayerState
    var titleSize: CGFloat = 15
    var artistSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playerState.hasTrack ? playerState.currentTrack.title : "Nothing playing")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundColor(Theme.text)
            Text(playerState.hasTrack ? playerState.currentTrack.artist : (playerState.serviceName ?? "Choose a service"))
                .font(.system(size: artistSize))
                .foregroundColor(Theme.secondaryText)
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

/// Text that scrolls slowly from right to left when it is wider than its space.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .semibold)
    var color: Color = .white
    var pointsPerSecond: CGFloat = 28

    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 32
            let overflow = textWidth > geometry.size.width
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !overflow)) { context in
                let elapsed = CGFloat(context.date.timeIntervalSince(start))
                let cycle = textWidth + gap
                let offset = overflow ? -(elapsed * pointsPerSecond).truncatingRemainder(dividingBy: max(cycle, 1)) : 0
                HStack(spacing: gap) {
                    label
                    if overflow { label }
                }
                .offset(x: offset)
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .clipped()
            .mask(
                LinearGradient(
                    stops: overflow
                        ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                           .init(color: .black, location: 0.94), .init(color: .clear, location: 1)]
                        : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                    startPoint: .leading, endPoint: .trailing)
            )
        }
        .onChange(of: text) { _ in start = Date() }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.preference(key: MarqueeWidthKey.self, value: proxy.size.width)
            })
            .onPreferenceChange(MarqueeWidthKey.self) { textWidth = $0 }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A small level display. The page does not give the real audio levels (most services
/// protect their audio), so the bars move in a calm pattern while music plays.
struct LevelBars: View {
    @ObservedObject var playerState: PlayerState
    var barCount = 7
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !playerState.isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(LinearGradient(
                            colors: [playerState.palette.accent2Color, playerState.palette.accentColor],
                            startPoint: .bottom, endPoint: .top))
                        .frame(width: barWidth, height: height(for: i, at: t))
                }
            }
            .frame(height: maxHeight, alignment: .bottom)
            .animation(.easeOut(duration: 0.12), value: t)
        }
    }

    private func height(for index: Int, at t: TimeInterval) -> CGFloat {
        guard playerState.isPlaying else { return 3 }
        let i = Double(index)
        // Sum of sine waves with different speeds per bar: no two bars move the same way.
        let wave = sin(t * (5.1 + i * 0.7) + i * 1.9) * 0.5
            + sin(t * (2.3 + i * 0.37) + i) * 0.3
            + sin(t * 8.7 + i * 2.6) * 0.2
        let center = 1 - abs(i - Double(barCount - 1) / 2) / Double(barCount) * 0.8
        let level = (wave * 0.5 + 0.5) * center
        return max(3, CGFloat(level) * maxHeight)
    }
}
