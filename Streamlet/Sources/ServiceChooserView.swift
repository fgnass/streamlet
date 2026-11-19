import AppKit
import SwiftUI

/// Colors of the service chooser. They come from the app icon: raspberry at the lower
/// left, orange at the upper right, on a black tile.
private enum Chooser {
    static let ink = Color(red: 0.024, green: 0.024, blue: 0.027)
    static let orange = Color(red: 1.0, green: 0.541, blue: 0.239)
    static let orangeStrong = Color(red: 1.0, green: 0.478, blue: 0.180)
    static let raspberry = Color(red: 0.761, green: 0.145, blue: 0.373)
    static let text = Color(red: 0.953, green: 0.945, blue: 0.941)
    static let mutedText = Color(red: 0.702, green: 0.682, blue: 0.675)
    static let danger = Color(red: 1.0, green: 0.604, blue: 0.561)

    /// The icon gradient for the primary button.
    static let buttonGradient: [Gradient.Stop] = [
        .init(color: Color(red: 0.612, green: 0.090, blue: 0.314), location: 0),
        .init(color: Color(red: 0.780, green: 0.196, blue: 0.184), location: 0.55),
        .init(color: Color(red: 0.933, green: 0.478, blue: 0.173), location: 1),
    ]
    static let buttonShadow = Color(red: 0.780, green: 0.196, blue: 0.184)
}

struct ServiceChooserView: View {
    @ObservedObject var playerState: PlayerState
    @State private var urlString: String = ""
    @State private var error: String? = nil
    @StateObject private var suggestionsManager = ServiceSuggestionsManager()
    @FocusState private var isFieldFocused: Bool

    /// True when the chooser covers a service page that is still loaded.
    private var isOverlay: Bool {
        if case .mock = playerState.dataSource { return false }
        return true
    }

    private func normalizedURLString(from input: String) -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        return trimmed
    }

    private func openURL() {
        error = nil
        let candidate = normalizedURLString(from: urlString)
        guard let url = URL(string: candidate), url.host != nil else {
            error = "This is not a valid address. Try something like music.example.com."
            return
        }
        playerState.connectToService(url: url.absoluteString)
        // Hide overlay if shown
        playerState.isShowingServiceChooserOverlay = false
    }

    private func connectToSuggestion(_ suggestion: ServiceSuggestion) {
        playerState.connectToService(url: suggestion.url)
        playerState.isShowingServiceChooserOverlay = false
    }

    @ViewBuilder
    private var background: some View {
        ZStack {
            if isOverlay {
                // Frosted veil above the live page, so the page stays visible but muted.
                Rectangle().fill(.ultraThinMaterial)
                Chooser.ink.opacity(0.72)
            } else {
                Chooser.ink
            }
            ChooserGlow().opacity(isOverlay ? 0.8 : 1)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header

                if !suggestionsManager.suggestions.isEmpty {
                    CenteredFlowLayout(spacing: 14) {
                        ForEach(suggestionsManager.suggestions) { suggestion in
                            ServiceSuggestionTile(
                                suggestion: suggestion,
                                faviconImage: suggestionsManager.getFaviconImage(for: suggestion),
                                action: { connectToSuggestion(suggestion) }
                            )
                        }
                    }
                    .frame(maxWidth: 690)
                    .padding(.top, 30)
                }

                addressForm
                    .frame(maxWidth: 560)
                    .padding(.top, 34)
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .foregroundColor(Chooser.text)
        .environment(\.colorScheme, .dark)
        .tint(Chooser.orange)
        .onAppear {
            // Prefill with current URL if available
            if case let .webService(url) = playerState.dataSource, urlString.isEmpty {
                urlString = url
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            // The icon builds itself up on the start screen; over a playing page it
            // is already there.
            AnimatedAppIcon(size: 92, plays: !isOverlay)
                .padding(.bottom, 14)
            Text("Choose a streaming service")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.44)
                .multilineTextAlignment(.center)
            Text("Pick a service, or open any web player by its address.")
                .font(.system(size: 13))
                .foregroundColor(Chooser.mutedText)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
    }

    private var addressForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open another address")
                .font(.system(size: 12.5))
                .foregroundColor(Chooser.mutedText)
                .padding(.leading, 2)
                .padding(.bottom, 8)

            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Chooser.mutedText)
                    TextField(
                        "Address",
                        text: $urlString,
                        prompt: Text("https://music.example.com").foregroundColor(Chooser.text.opacity(0.56))
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(Chooser.text)
                    .focused($isFieldFocused)
                    .onSubmit { openURL() }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glass(cornerRadius: 12, edge: error == nil ? nil : Chooser.danger.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Chooser.orange, lineWidth: 2)
                        .padding(-4)
                        .opacity(isFieldFocused ? 1 : 0)
                )
                .onChange(of: urlString) { _ in error = nil }

                Button(action: { openURL() }) {
                    Text("Open")
                }
                .buttonStyle(IconGradientButtonStyle())
                // The system focus ring is a rectangle and does not match the rounded
                // button, and Return already triggers it.
                .focusable(false)
                .keyboardShortcut(.defaultAction)

                if isOverlay {
                    Button(action: { playerState.isShowingServiceChooserOverlay = false }) {
                        Text("Cancel")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .focusable(false)
                }
            }

            if let error = error {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundColor(Chooser.danger)
                    .padding(.leading, 2)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Background glow

/// The orange and raspberry glow of the app icon: one soft light near the middle of
/// each color, and a wider one in the corner of the same color.
private struct ChooserGlow: View {
    private struct Spot {
        let color: Color
        let center: CGPoint
        /// Radius of the ellipse as a fraction of the view's width and height.
        let radius: CGSize
    }

    private static let spots = [
        Spot(color: Chooser.orangeStrong.opacity(0.30), center: CGPoint(x: 0.76, y: 0.44), radius: CGSize(width: 0.34, height: 0.40)),
        Spot(color: Chooser.raspberry.opacity(0.40), center: CGPoint(x: 0.26, y: 0.70), radius: CGSize(width: 0.36, height: 0.44)),
        Spot(color: Chooser.orangeStrong.opacity(0.26), center: CGPoint(x: 1.0, y: 0.0), radius: CGSize(width: 0.62, height: 0.60)),
        Spot(color: Chooser.raspberry.opacity(0.30), center: CGPoint(x: 0.0, y: 1.0), radius: CGSize(width: 0.58, height: 0.62)),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Self.spots.indices, id: \.self) { index in
                    let spot = Self.spots[index]
                    // The color fades out at 72% of the ellipse radius.
                    Rectangle()
                        .fill(EllipticalGradient(
                            colors: [spot.color, spot.color.opacity(0)],
                            center: .center,
                            startRadiusFraction: 0,
                            endRadiusFraction: 0.5
                        ))
                        .frame(
                            width: 2 * spot.radius.width * geo.size.width * 0.72,
                            height: 2 * spot.radius.height * geo.size.height * 0.72
                        )
                        .position(
                            x: spot.center.x * geo.size.width,
                            y: spot.center.y * geo.size.height
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Glass

/// A soft shadow that shows only outside the shape, also below a translucent fill.
/// `inset` makes the shadow smaller than the shape, so it shows mostly below it.
private struct OuterShadow<S: InsettableShape>: View {
    let shape: S
    let color: Color
    let blur: CGFloat
    let y: CGFloat
    let inset: CGFloat

    var body: some View {
        shape.inset(by: inset)
            .fill(color)
            .blur(radius: blur)
            .offset(y: y)
            .mask(OutsideOf(shape: shape, margin: blur * 3 + abs(y)).fill(style: FillStyle(eoFill: true)))
            .allowsHitTesting(false)
    }
}

/// The area around a shape: a larger rectangle with the shape cut out.
private struct OutsideOf<S: Shape>: Shape {
    let shape: S
    let margin: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -margin, dy: -margin))
        path.addPath(shape.path(in: rect))
        return path
    }
}

/// Frosted glass: a light gradient fill, a thin edge, a highlight on the top edge and
/// a shadow below.
private struct GlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    var highlighted = false
    var edge: Color? = nil
    var shadow = Color.black.opacity(0.9)

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let lift: Double = highlighted ? 0.05 : 0
        content
            .background(
                ZStack {
                    OuterShadow(shape: shape, color: shadow, blur: 13, y: 12, inset: 16)
                    shape.fill(LinearGradient(
                        colors: [Color.white.opacity(0.10 + lift), Color.white.opacity(0.035 + lift)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                }
            )
            .overlay(
                shape.strokeBorder(edge ?? Color.white.opacity(highlighted ? 0.12 : 0.07), lineWidth: 1)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(highlighted ? 0.28 : 0.18), location: 0),
                            .init(color: Color.white.opacity(0), location: min(0.25, 8 / max(cornerRadius * 4, 1))),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
    }
}

private extension View {
    func glass(cornerRadius: CGFloat, highlighted: Bool = false, edge: Color? = nil, shadow: Color = Color.black.opacity(0.9)) -> some View {
        modifier(GlassModifier(cornerRadius: cornerRadius, highlighted: highlighted, edge: edge, shadow: shadow))
    }
}

// MARK: - Tiles

/// Lays out its children in rows and centers each row, so a short last row stays
/// in the middle.
private struct CenteredFlowLayout: Layout {
    var spacing: CGFloat

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var width: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.isEmpty ? size.width : width + spacing + size.width
            if needed > maxWidth, !current.isEmpty {
                rows.append(current)
                current = [index]
                width = size.width
            } else {
                current.append(index)
                width = needed
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private func size(of row: [Int], _ subviews: Subviews) -> CGSize {
        let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
        let width = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(row.count - 1, 0))
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rowSizes = rows(for: subviews, maxWidth: maxWidth).map { size(of: $0, subviews) }
        let width = rowSizes.map(\.width).max() ?? 0
        let height = rowSizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rowSizes.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            let rowSize = size(of: row, subviews)
            var x = bounds.midX - rowSize.width / 2
            for index in row {
                let itemSize = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowSize.height - itemSize.height) / 2),
                    proposal: ProposedViewSize(itemSize)
                )
                x += itemSize.width + spacing
            }
            y += rowSize.height + spacing
        }
    }
}

struct ServiceSuggestionTile: View {
    let suggestion: ServiceSuggestion
    let faviconImage: NSImage?
    let action: () -> Void

    private static let iconSize: CGFloat = 44

    @ViewBuilder
    private var icon: some View {
        if let image = faviconImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
        } else if suggestion.isLoadingFavicon {
            ShimmerPlaceholder()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            // Fetch finished without a usable icon: fall back to the initial.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                Text(String(suggestion.name.prefix(1)))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Chooser.mutedText)
            }
            .frame(width: Self.iconSize, height: Self.iconSize)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                icon
                    .animation(.easeInOut(duration: 0.2), value: faviconImage != nil)

                Text(suggestion.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    // Wrap long names ("YouTube Music") instead of truncating them.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(TileButtonStyle())
        // Hover already conveys the target; the rectangular system focus ring
        // would sit outside the rounded tile.
        .focusable(false)
    }
}

/// Glass tile that lifts and gets an orange shadow on hover.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let lifted = isHovered && !configuration.isPressed && !reduceMotion
            configuration.label
                .foregroundColor(Chooser.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(width: 124, height: 112)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .glass(
                    cornerRadius: 16,
                    highlighted: isHovered,
                    shadow: isHovered ? Chooser.orangeStrong.opacity(0.55) : Color.black.opacity(0.9)
                )
                .offset(y: lifted ? -2 : 0)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

/// Soft sweep while a favicon is still loading.
struct ShimmerPlaceholder: View {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            Color.white.opacity(0.09).overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.2),
                        .init(color: Color.white.opacity(0.20), location: 0.5),
                        .init(color: .clear, location: 0.8),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width)
                .offset(x: phase * geo.size.width)
                .opacity(reduceMotion ? 0 : 1)
            )
            .clipped()
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - Buttons

/// Primary button in the gradient of the app icon, with a gloss layer so it looks
/// rounded. It gets brighter on hover and sinks in when pressed.
private struct IconGradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GradientButton(configuration: configuration)
    }

    private struct GradientButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: Color(red: 0.27, green: 0.03, blue: 0.08).opacity(0.55), radius: 0.5, x: 0, y: 1)
                .padding(.horizontal, 22)
                .frame(height: 44)
                .background(
                    ZStack {
                        OuterShadow(
                            shape: shape,
                            color: Chooser.buttonShadow.opacity(pressed ? 0.6 : 0.75),
                            blur: pressed ? 5 : 11,
                            y: pressed ? 4 : 12,
                            inset: pressed ? 6 : 10
                        )
                        shape.fill(Color.black.opacity(0.6))
                            .offset(y: 1)
                            .blur(radius: 0.5)
                        shape.fill(LinearGradient(
                            stops: Chooser.buttonGradient,
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        ))
                        shape.fill(LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.26), location: 0),
                                .init(color: Color.white.opacity(0), location: 0.46),
                                .init(color: Color.black.opacity(0.16), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        if pressed {
                            // Inner shadow at the top while the button is pressed in.
                            shape.fill(LinearGradient(
                                colors: [Color.black.opacity(0.30), Color.black.opacity(0)],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.25)
                            ))
                        }
                        shape.strokeBorder(
                            LinearGradient(
                                stops: pressed
                                    ? [
                                        .init(color: Color.black.opacity(0.35), location: 0),
                                        .init(color: Color.black.opacity(0), location: 0.15),
                                        .init(color: Color.white.opacity(0), location: 0.85),
                                        .init(color: Color.white.opacity(0.12), location: 1),
                                    ]
                                    : [
                                        .init(color: Color.white.opacity(0.50), location: 0),
                                        .init(color: Color.white.opacity(0), location: 0.15),
                                        .init(color: Color.black.opacity(0), location: 0.85),
                                        .init(color: Color.black.opacity(0.35), location: 1),
                                    ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    }
                    .brightness(pressed ? -0.03 : (isHovered ? 0.05 : 0))
                )
                .offset(y: pressed ? 1 : 0)
                .contentShape(shape)
                .animation(.easeOut(duration: 0.15), value: pressed)
                .animation(.easeOut(duration: 0.15), value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}

/// Text-only button for secondary actions such as Cancel.
private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 14))
                .foregroundColor(isHovered ? Chooser.text : Chooser.mutedText)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovered = $0 }
        }
    }
}
