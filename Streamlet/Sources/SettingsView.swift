import SwiftUI
import WebKit
import ServiceManagement

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case menuBar = "Menu Bar"
        case miniPlayer = "Miniplayer"
        case notch = "Notch"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .menuBar: return "menubar.rectangle"
            case .miniPlayer: return "pip"
            case .notch: return "macbook"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 14))
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(
                            selectedTab == tab ? .accentColor : .secondary
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.1) : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Tab content
            ScrollView {
                Group {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsView()
                    case .menuBar:
                        MenuBarSettingsView()
                    case .miniPlayer:
                        MiniPlayerSettingsView()
                    case .notch:
                        NotchSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 480, height: 420)
    }
}

struct GeneralSettingsView: View {
    /// Read from the system: the login item can also change in System Settings.
    @State private var openAtStartup = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Startup")
                .font(.headline)
                .foregroundColor(.primary)

            ToggleRow(
                title: "Open at Startup",
                description: "Automatically launch Streamlet when you log in",
                isOn: Binding(
                    get: { openAtStartup },
                    set: { setOpenAtStartup($0) }
                )
            )

            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            openAtStartup = SMAppService.mainApp.status == .enabled
        }
    }

    private func setOpenAtStartup(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Could not change the login item: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        openAtStartup = status == .enabled
        if enabled, status == .requiresApproval {
            loginItemError = "Allow Streamlet in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}


struct MenuBarSettingsView: View {
    @AppStorage("enableMenuBarItem") private var enableMenuBarItem = true
    @AppStorage("enableMenuBarPlayerControls") private var enableMenuBarPlayerControls = false
    @AppStorage("menuBarIcon") private var menuBarIcon = "auto"
    @AppStorage("menuBarShowsProgress") private var menuBarShowsProgress = true
    @AppStorage("enablePopover") private var enablePopover = true
    @AppStorage("songInfoInMenuBar") private var songInfoInMenuBar = "always"
    @AppStorage("songInfoDetails") private var songInfoDetails = "song"
    @AppStorage("songInfoWidth") private var songInfoWidth: Double = 100
    @AppStorage("fixedSongInfoWidth") private var fixedSongInfoWidth = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "Menu bar item") {
                SettingRow("Show in menu bar") {
                    Toggle("", isOn: $enableMenuBarItem).toggleStyle(.switch)
                }
                SettingRow("Icon") {
                    Picker("", selection: $menuBarIcon) {
                        Text("Automatic").tag("auto")
                        Text("Cover").tag("albumArt")
                        Text("App icon").tag("appIcon")
                        Text("Service icon").tag("serviceIcon")
                        Text("None").tag("hidden")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .disabled(!enableMenuBarItem)
                SettingRow("Progress line") {
                    Toggle("", isOn: $menuBarShowsProgress).toggleStyle(.switch)
                }
                .disabled(!enableMenuBarItem)
                SettingRow("Play, back and next buttons") {
                    Toggle("", isOn: $enableMenuBarPlayerControls).toggleStyle(.switch)
                }
                .disabled(!enableMenuBarItem)
                SettingRow("Open player on click") {
                    Toggle("", isOn: $enablePopover).toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "Track text") {
                SettingRow("Show") {
                    Picker("", selection: $songInfoInMenuBar) {
                        Text("Always").tag("always")
                        Text("While playing").tag("whenPlaying")
                        Text("Never").tag("never")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                SettingRow("Content") {
                    Picker("", selection: $songInfoDetails) {
                        Text("Title").tag("song")
                        Text("Artist").tag("artist")
                        Text("Artist – Title").tag("artistAndTrack")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .disabled(songInfoInMenuBar == "never")
                SettingRow("Same width for all tracks", help: "On: the text always uses the width below. Off: the width follows the text.") {
                    Toggle("", isOn: $fixedSongInfoWidth).toggleStyle(.switch)
                }
                .disabled(songInfoInMenuBar == "never")
                SettingRow("Width") {
                    HStack {
                        Slider(value: $songInfoWidth, in: 75...400, step: 25)
                            .frame(width: 150)
                        Text("\(Int(songInfoWidth)) pt")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(songInfoInMenuBar == "never" || !fixedSongInfoWidth)
            }
            .disabled(!enableMenuBarItem)
        }
    }
}

struct MiniPlayerSettingsView: View {
    @AppStorage("showMiniPlayer") private var showMiniPlayer = false
    @AppStorage("miniPlayerOnTop") private var onTop = true
    @AppStorage("miniPlayerDocks") private var docks = true
    @AppStorage("miniPlayerShowsVideo") private var showsVideo = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "Miniplayer") {
                SettingRow("Show miniplayer") {
                    Toggle("", isOn: $showMiniPlayer).toggleStyle(.switch)
                }
                SettingRow("Keep above other windows") {
                    Toggle("", isOn: $onTop).toggleStyle(.switch)
                }
                SettingRow("Hide at the screen edge", help: "Drag the miniplayer against the left or right screen edge. It then hides and leaves a narrow tab. Move the pointer over the tab to show it.") {
                    Toggle("", isOn: $docks).toggleStyle(.switch)
                }
                SettingRow("Show the video when there is one", help: "For services that play videos, for example YouTube. Protected videos show the cover.") {
                    Toggle("", isOn: $showsVideo).toggleStyle(.switch)
                }
            }
            Text("Drag a corner of the miniplayer to change its size. The layout follows the size: only the cover, a strip, or the cover with details.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }
}

struct NotchSettingsView: View {
    @AppStorage("notchEnabled") private var enabled = true
    @AppStorage("notchShowsEars") private var showsEars = true
    @AppStorage("notchShowsTrackChange") private var showsTrackChange = true
    @AppStorage("notchOnDisplaysWithoutNotch") private var withoutNotch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "Notch") {
                SettingRow("Show player at the notch") {
                    Toggle("", isOn: $enabled).toggleStyle(.switch)
                }
                SettingRow("Cover and level next to the notch") {
                    Toggle("", isOn: $showsEars).toggleStyle(.switch)
                }
                .disabled(!enabled)
                SettingRow("Show new tracks for a moment") {
                    Toggle("", isOn: $showsTrackChange).toggleStyle(.switch)
                }
                .disabled(!enabled)
                SettingRow("Also on displays without a notch", help: "Streamlet then draws a notch at the top of the main display.") {
                    Toggle("", isOn: $withoutNotch).toggleStyle(.switch)
                }
                .disabled(!enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Click: play or pause")
                Text("Scroll up or down: move in the track")
                Text("Swipe left or right (or Shift + scroll): next or previous track")
                Text("Keep the pointer on the notch: title and time")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
        }
    }
}

/// A titled group of setting rows with separators.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                _VariadicView.Tree(DividedLayout()) { content }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
    }
}

/// Puts a divider between the rows of a group.
private struct DividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last { Divider().padding(.leading, 16) }
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder let control: Control

    init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            if let help {
                InfoButton(text: help)
            }
            Spacer()
            control
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// A small info icon. It shows its text in a popover on hover (after a short delay)
/// and on click. A click keeps the popover open until the next click outside.
struct InfoButton: View {
    let text: String
    @State private var isShown = false
    @State private var isPinned = false
    @State private var isHovering = false
    @State private var hoverTask: DispatchWorkItem?

    var body: some View {
        Button(action: {
            hoverTask?.cancel()
            isPinned.toggle()
            isShown = isPinned
        }) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(isHovering || isShown ? .primary : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                let task = DispatchWorkItem { isShown = true }
                hoverTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
            } else if !isPinned {
                isShown = false
            }
        }
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
        }
        .onChange(of: isShown) { shown in
            if !shown { isPinned = false }
        }
        .accessibilityLabel("Info")
        .accessibilityHint(text)
    }
}

struct ToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
    }
}
