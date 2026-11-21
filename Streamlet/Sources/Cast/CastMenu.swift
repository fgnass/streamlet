import AppKit
import Combine
import SwiftUI

/// The menu of cast devices. The same menu appears as the "Cast To" submenu of the menu bar
/// item and as the menu of the cast button in the player panel. While it is open, it shows
/// new devices and the cast status at once.
final class CastDeviceMenu: NSObject, NSMenuDelegate {
    static let shared = CastDeviceMenu()

    /// Closes the player panel. A permission dialog of macOS would open behind it.
    static var closePanel: (() -> Void)?
    private static let searchedKey = "castDevicesSearched"

    private var openMenus = NSHashTable<NSMenu>.weakObjects()
    private var observation: AnyCancellable?
    private lazy var popupMenu = makeMenu(isPopup: true)
    private var popupMenus = NSHashTable<NSMenu>.weakObjects()

    /// A menu with the devices, for use as a submenu.
    func makeMenu(isPopup: Bool = false) -> NSMenu {
        let menu = NSMenu(title: "Cast To")
        menu.autoenablesItems = false
        menu.delegate = self
        if isPopup { popupMenus.add(menu) }
        return menu
    }

    /// Opens the device menu at the mouse pointer.
    func popUp() {
        popupMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !UserDefaults.standard.bool(forKey: Self.searchedKey) {
            // The first search asks for access to the local network.
            UserDefaults.standard.set(true, forKey: Self.searchedKey)
            Self.closePanel?()
        }
        CastController.shared.startDiscovery()
        populate(menu)
        openMenus.add(menu)
        if observation == nil {
            observation = CastController.shared.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // objectWillChange comes before the change.
                    DispatchQueue.main.async { self?.populateOpenMenus() }
                }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenus.remove(menu)
        if openMenus.count == 0 { observation = nil }
    }

    private func populateOpenMenus() {
        openMenus.allObjects.forEach(populate)
    }

    private func populate(_ menu: NSMenu) {
        let cast = CastController.shared
        menu.removeAllItems()
        if popupMenus.contains(menu), #available(macOS 14, *) {
            menu.addItem(.sectionHeader(title: "Cast To"))
        }
        if cast.devices.isEmpty {
            let item = NSMenuItem(title: "Searching for Devices…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for device in cast.devices {
            menu.addItem(item(for: device, status: cast.status))
        }
        if cast.activeDevice != nil {
            menu.addItem(.separator())
            let stop = NSMenuItem(title: "Stop Casting", action: #selector(stopCasting), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        } else if case .failed(nil, let message) = cast.status {
            menu.addItem(.separator())
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private func item(for device: CastDevice, status: CastController.Status) -> NSMenuItem {
        let item = NSMenuItem(title: device.name, action: #selector(select(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = device.id
        item.image = NSImage(systemSymbolName: device.symbolName, accessibilityDescription: nil)
        var detail: String?
        switch status {
        case .connecting(let active) where active == device:
            item.state = .mixed
            detail = "Connecting…"
        case .casting(let active) where active == device:
            item.state = .on
            detail = "Playing"
        case .failed(let failed?, let message) where failed == device:
            detail = message
        default:
            break
        }
        if let detail {
            if #available(macOS 14.4, *) {
                item.subtitle = detail
            } else {
                item.title = "\(device.name) – \(detail)"
            }
        }
        return item
    }

    @objc private func select(_ sender: NSMenuItem) {
        let cast = CastController.shared
        guard let id = sender.representedObject as? String,
              let device = cast.devices.first(where: { $0.id == id }) else { return }
        // Casting can ask for permission to record the audio.
        Self.closePanel?()
        cast.toggle(device)
    }

    @objc private func stopCasting() {
        CastController.shared.stop()
    }
}

extension CastDevice {
    /// A speaker for audio devices and groups, a TV for devices with a screen.
    var symbolName: String {
        let model = model.lowercased()
        if model.contains("group") { return "hifispeaker.2" }
        if model.contains("hub") || model.contains("tv") { return "tv" }
        if ["audio", "mini", "home", "speaker", "max"].contains(where: model.contains) { return "hifispeaker" }
        return "tv"
    }
}

/// The cast button of the player panel. It pulses while Streamlet connects.
struct CastButton: View {
    @ObservedObject var cast = CastController.shared
    var tint: Color
    @State private var pulse = false

    private var isConnecting: Bool {
        if case .connecting = cast.status { return true }
        return false
    }

    var body: some View {
        if CastController.isSupported {
            IconButton(
                systemName: cast.activeDevice == nil ? "hifispeaker" : "hifispeaker.fill",
                size: 13,
                isDim: true,
                isActive: cast.activeDevice != nil,
                help: cast.activeDevice.map { "Casting to \($0.name)" } ?? "Cast to a device",
                tint: tint
            ) { CastDeviceMenu.shared.popUp() }
            .opacity(isConnecting && pulse ? 0.35 : 1)
            .animation(isConnecting ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse)
            .onChange(of: isConnecting) { pulse = $0 }
            .onAppear { pulse = isConnecting }
        }
    }
}

// MARK: - Toast

/// A short notice below the menu bar item: Streamlet connects, plays on a device, or failed.
final class CastToastController {
    private let panel: NSPanel
    private let model = CastToastModel()
    private let anchor: () -> NSRect?
    private var observation: AnyCancellable?
    private var previous: CastController.Status = .idle
    private var hideWork: DispatchWorkItem?

    /// `anchor` gives the frame of the menu bar item on the screen.
    init(anchor: @escaping () -> NSRect?) {
        self.anchor = anchor
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CastToastView(model: model))

        // DispatchQueue.main and not RunLoop.main: the status changes while a menu is open,
        // and RunLoop.main waits until the menu closes.
        observation = CastController.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.update(status) }
    }

    private func update(_ status: CastController.Status) {
        defer { previous = status }
        switch status {
        case .connecting(let device):
            show(.init(symbol: nil, title: "Connecting to \(device.name)…"), hideAfter: nil)
        case .casting(let device):
            show(.init(symbol: "hifispeaker.fill", title: "Playing on \(device.name)"), hideAfter: 2.5)
        case .failed(let device, let message):
            show(.init(symbol: "exclamationmark.triangle.fill",
                       title: "Cannot cast to \(device?.name ?? "the device")",
                       detail: message), hideAfter: 6)
        case .idle:
            switch previous {
            case .connecting, .casting:
                show(.init(symbol: "laptopcomputer", title: "Playing on this Mac"), hideAfter: 2)
            default:
                hide()
            }
        }
    }

    private func show(_ content: CastToastModel.Content, hideAfter delay: TimeInterval?) {
        model.content = content
        hideWork?.cancel()

        let hosting = panel.contentView!
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if let anchor = anchor() {
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? anchor
            var x = anchor.midX - size.width / 2
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            panel.setFrame(NSRect(x: x, y: visible.maxY - 5 - size.height, width: size.width, height: size.height),
                           display: true)
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        panel.invalidateShadow()

        if let delay {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
        })
    }
}

final class CastToastModel: ObservableObject {
    struct Content: Equatable {
        /// nil shows a spinner.
        var symbol: String?
        var title: String
        var detail: String? = nil
    }

    @Published var content = Content(symbol: nil, title: "")
}

struct CastToastView: View {
    @ObservedObject var model: CastToastModel

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let symbol = model.content.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.content.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                if let detail = model.content.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}
