import AppKit
import SwiftUI
import WebKit
import Combine

@main
struct StreamletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var playerState = PlayerState()
    @StateObject private var windowManager = WindowManager()

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Cmd+, opens Streamlet's own settings window, not the empty Settings scene.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, PlayerDelegate,
    PopoverDelegate, NSMenuDelegate
{
    var statusItem: NSStatusItem!
    var controlsStatusItem: NSStatusItem!
    private var playerPanel: PlayerPanelController!
    private var miniPlayer: MiniPlayerController!
    private var notch: NotchController!
    private var castToast: CastToastController!
    private lazy var contextMenu = makeContextMenu()
    var settingsWindow: NSWindow?
    var streamingWindow: NSWindow?
    var playerState: PlayerState!
    var menuBarView: MenuBarView!
    var webViewController: WebViewController?
    private var cancellables = Set<AnyCancellable>()
    /// The dock icon for the open service, or nil for the app icon of the bundle.
    private var dockIcon: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Line-buffered output, so logs reach a redirected stdout at once.
        setvbuf(stdout, nil, _IOLBF, 0)
        PreviewRenderer.runIfRequested()
        CastController.shared.runDebugIfRequested()
        #endif
        playerState = PlayerState()
        // Open the service from the last session again
        if let lastService = PlayerState.lastServiceURL {
            playerState.connectToService(url: lastService)
        }
        setupMenuBar()
        setupPlayers()
        
        // Open empty streaming window at startup
        openEmptyStreamingWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close the media player on the cast device, so that it does not wait for the stream.
        CastController.shared.stopAndWait()
    }

    func setupMenuBar() {
        // Controls status item (no popover handling) - created first to appear on the right
        controlsStatusItem = NSStatusBar.system.statusItem(withLength: 68)

        if let controlsButton = controlsStatusItem.button {
            // Left clicks go to the buttons in the view. A right click opens the menu.
            controlsButton.target = self
            controlsButton.action = #selector(controlsRightClicked(_:))
            controlsButton.sendAction(on: [.rightMouseDown])
            let controlsView = MenuBarControlsView(playerState: playerState, popoverDelegate: self)
            let controlsHostingView = NSHostingView(rootView: controlsView)
            controlsButton.addSubview(controlsHostingView)

            // Set up auto-layout constraints
            controlsHostingView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                controlsHostingView.centerXAnchor.constraint(equalTo: controlsButton.centerXAnchor),
                controlsHostingView.centerYAnchor.constraint(equalTo: controlsButton.centerYAnchor),
                controlsHostingView.heightAnchor.constraint(equalToConstant: 22),
                controlsHostingView.widthAnchor.constraint(equalToConstant: 68),
            ])
        }

        // Main status item for icon/text (handles popover) - created second to appear on the left
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Create custom menu bar view without controls
            menuBarView = MenuBarView(
                playerState: playerState, statusItem: statusItem, popoverDelegate: self)
            let hostingView = PassthroughHostingView(rootView: menuBarView)
            button.addSubview(hostingView)

            // A click opens the player, a right click or Control-click the menu.
            button.target = self
            button.action = #selector(menuBarButtonPressed(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])

            // Set up auto-layout constraints
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostingView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                hostingView.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
    }

    func setupPlayers() {
        playerPanel = PlayerPanelController(playerState: playerState, delegate: self)
        miniPlayer = MiniPlayerController(playerState: playerState, delegate: self)
        notch = NotchController(playerState: playerState, delegate: self)
        CastDeviceMenu.closePanel = { [weak self] in self?.playerPanel.close() }
        CastController.shared.attach(playerState)
        castToast = CastToastController { [weak self] in
            guard let button = self?.statusItem.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
    }

    @objc func menuBarButtonPressed(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showContextMenu(for: statusItem)
        } else {
            togglePopover()
        }
    }

    @objc func controlsRightClicked(_ sender: NSStatusBarButton) {
        showContextMenu(for: controlsStatusItem)
    }

    // MARK: - Context menu

    /// Opens the menu below a menu bar item, like the menu of any menu bar item.
    private func showContextMenu(for item: NSStatusItem) {
        playerPanel?.close()
        item.menu = contextMenu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        _ = add("Web Player", #selector(menuOpenWebPlayer))
        _ = add("Show Miniplayer", #selector(menuToggleMiniPlayer))
        _ = add("Change Service…", #selector(menuChangeService))
        if CastController.isSupported {
            let cast = menu.addItem(withTitle: "Cast To", action: nil, keyEquivalent: "")
            cast.submenu = CastDeviceMenu.shared.makeMenu()
        }
        _ = add("Clear Website Data…", #selector(menuClearServiceData))
        _ = add("Settings…", #selector(menuOpenSettings))
        menu.addItem(.separator())
        _ = add("Quit Streamlet", #selector(menuQuit))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        let showsMiniPlayer = UserDefaults.standard.bool(forKey: "showMiniPlayer")
        menu.item(at: 1)?.title = showsMiniPlayer ? "Hide Miniplayer" : "Show Miniplayer"
    }

    // The menu runs in its own event loop. Actions that open windows or alerts wait for it to end.
    @objc private func menuOpenWebPlayer() { DispatchQueue.main.async { self.openWebPlayer() } }
    @objc private func menuToggleMiniPlayer() { toggleMiniPlayer() }
    @objc private func menuChangeService() { DispatchQueue.main.async { self.changeService() } }
    @objc private func menuClearServiceData() { DispatchQueue.main.async { self.clearServiceData() } }
    @objc private func menuOpenSettings() { DispatchQueue.main.async { self.openSettings() } }
    @objc private func menuQuit() { quitApp() }

    /// Opens the player panel below the menu bar item.
    func showPlayerPanel() {
        let enablePopover = UserDefaults.standard.object(forKey: "enablePopover") as? Bool ?? true
        guard enablePopover, let button = statusItem.button, let window = button.window else { return }
        var anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        // With the controls next to the item, center the panel below both.
        if UserDefaults.standard.bool(forKey: "enableMenuBarPlayerControls"),
           let controls = controlsStatusItem.button, let controlsWindow = controls.window {
            anchor = anchor.union(controlsWindow.convertToScreen(controls.convert(controls.bounds, to: nil)))
        }
        playerPanel.show(below: anchor, anchorWindow: window)
    }

    func togglePopover() {
        if playerPanel.isShown {
            playerPanel.close()
        } else {
            showPlayerPanel()
        }
    }

    func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func toggleMiniPlayer() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "showMiniPlayer"), forKey: "showMiniPlayer")
    }

    func openSettings() {
        playerPanel?.close()

        // Transform to regular app temporarily to allow window activation
        showInDock()

        // Reuse existing window or create new one
        if settingsWindow == nil {
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )

            settingsWindow?.title = "Streamlet Settings"
            settingsWindow?.center()
            settingsWindow?.isReleasedWhenClosed = false  // Prevent deallocation on close

            let settingsView = SettingsView()
            let hostingView = NSHostingView(rootView: settingsView)
            settingsWindow?.contentView = hostingView

            // Set delegate to handle window close
            settingsWindow?.delegate = self
        }

        // Activate the app and make window key
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openWebPlayer() {
        // A window opens: the player panel would cover it.
        playerPanel?.close()
        // Check if streaming window already exists
        if let existingWindow = streamingWindow {
            // Window exists, just bring it to front
            showInDock()
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // No existing window, create a new one
            openEmptyStreamingWindow()
        }
    }

    /// Removes cookies, storage and caches of all websites. Streamlet keeps only streaming
    /// services (and their sign-in pages) in its data store, so this signs out of all of them.
    func clearServiceData() {
        // A window opens: the player panel would cover it.
        playerPanel?.close()
        let alert = NSAlert()
        alert.messageText = "Clear website data?"
        alert.informativeText = "This removes cookies, storage and caches of all services. You will be signed out of every service."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Data")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let dataStore = WKWebsiteDataStore.default()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [weak self] in
            DispatchQueue.main.async { self?.webViewController?.webView?.reloadFromOrigin() }
        }
    }

    // Allow changing the service: show the chooser and disconnect
    func changeService() {
        // A window opens: the player panel would cover it.
        playerPanel?.close()
        // Ensure streaming window is visible
        openWebPlayer()
        // Show overlay only if a service is already active; otherwise base chooser is shown
        switch playerState.dataSource {
        case .webService:
            playerState.isShowingServiceChooserOverlay = true
        case .mock:
            playerState.isShowingServiceChooserOverlay = false
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == streamingWindow {
            // Don't actually close the streaming window, just hide it to keep the player alive
            sender.orderOut(nil)
            // Return to menu bar app mode when streaming window is hidden
            NSApp.setActivationPolicy(.accessory)
            return false  // Prevent actual closing
        }
        return true  // Allow other windows to close normally
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == settingsWindow {
            // Return to menu bar app mode when settings close
            NSApp.setActivationPolicy(.accessory)
        }
        // Note: streamingWindow won't actually close due to windowShouldClose returning false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow == streamingWindow {
            webViewController?.webView?.becomeFirstResponder()
        }
    }
    
    // MARK: - Streaming Service
    
    func openEmptyStreamingWindow() {
        // If window already exists, just show it
        if let existingWindow = streamingWindow {
            showInDock()
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Switch to regular app to show window
        showInDock()
        
        // Create streaming window with titled style (hidden/transparent title bar)
        // Web players are made for wide browser windows: start wide, but fit the screen.
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let defaultSize = NSSize(width: min(1280, visible.width * 0.85),
                                 height: min(860, visible.height * 0.85))
        streamingWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        streamingWindow?.titleVisibility = .hidden
        streamingWindow?.titlebarAppearsTransparent = true
        streamingWindow?.titlebarSeparatorStyle = .none
        streamingWindow?.isMovableByWindowBackground = true
        streamingWindow?.backgroundColor = NSColor.clear  // Transparent background for rounded corners
        streamingWindow?.isOpaque = false
        streamingWindow?.hasShadow = true  // Add shadow for depth
        streamingWindow?.center()
        streamingWindow?.delegate = self
        streamingWindow?.isReleasedWhenClosed = false  // Keep window in memory when closed
        
        // Create web view controller
        webViewController = WebViewController()

        // Set web view control on player state
        playerState.webViewControl = webViewController

        // Create a wrapper view; native title bar/controls are used (no custom traffic lights)
        let contentView = ZStack(alignment: .top) {
            // Main content switches between chooser and web view based on state
            StreamingContentView(
                playerState: playerState,
                onWebViewChange: { [weak self] newWebView in
                    self?.webViewController?.webView = newWebView
                }
            )

            // Draggable area limited to the very top
            DraggableView()
                .frame(height: 0)
                .frame(maxWidth: .infinity, alignment: .top)
                .background(Color.black.opacity(0.01))
        }
        
        // Add a visible background to the window content
        let wrappedContent = ZStack(alignment: .top) {
            // Background fill for transparent window
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()

            contentView
        }

        // Set content view
        let hostingView = NSHostingView(rootView: wrappedContent)
        // The window keeps its own size. Without this, the window takes the ideal size of
        // the content, for example a narrow and very tall window for the service chooser.
        hostingView.sizingOptions = []
        streamingWindow?.contentView = hostingView
        streamingWindow?.contentMinSize = NSSize(width: 480, height: 400)
        // Keep the size and position the user chose, also across launches.
        streamingWindow?.setFrameAutosaveName("StreamletWebPlayer")
        
        // Round the entire window (including title bar) so traffic lights sit "inside"
        if let cv = streamingWindow?.contentView, let container = cv.superview {
            container.wantsLayer = true
            container.layer?.cornerRadius = 10
            container.layer?.masksToBounds = true
        }
        streamingWindow?.makeKeyAndOrderFront(nil)
        
        // Activate the app to bring window to front
        NSApp.activate(ignoringOtherApps: true)
        
        // Force menu bar to refresh when track changes
        setupMenuBarRefresh()
    }
    
    func setupMenuBarRefresh() {
        // Observe changes to force menu bar updates
        playerState.$currentTrack
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Recreate the menu bar view with updated state
                self.refreshMenuBar()
            }
            .store(in: &cancellables)
        
        // The dock icon shows the icon of the open service on the app icon tile.
        playerState.$serviceIcon
            .combineLatest(playerState.$isConnectedToService)
            .receive(on: RunLoop.main)
            .sink { [weak self] icon, isConnected in
                self?.updateDockIcon(serviceIcon: isConnected ? icon : nil)
            }
            .store(in: &cancellables)
    }
    
    func refreshMenuBar() {
        guard let button = statusItem?.button else { return }
        
        // Remove old view
        button.subviews.forEach { $0.removeFromSuperview() }
        
        // Create new menu bar view with current state
        menuBarView = MenuBarView(
            playerState: playerState,
            statusItem: statusItem,
            popoverDelegate: self
        )
        
        let hostingView = PassthroughHostingView(rootView: menuBarView)
        button.addSubview(hostingView)
        
        // Set up auto-layout constraints
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            hostingView.heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    
    func updateDockIcon(serviceIcon: NSImage?) {
        guard let serviceIcon else {
            setDockIcon(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = DockIcon.make(serviceIcon: serviceIcon)
            DispatchQueue.main.async {
                // Ignore the result when the service changed in the meantime.
                guard let self, self.playerState.serviceIcon === serviceIcon,
                      self.playerState.isConnectedToService else { return }
                self.setDockIcon(image)
            }
        }
    }

    private func setDockIcon(_ image: NSImage?) {
        dockIcon = image
        if NSApp.activationPolicy() == .regular {
            NSApp.applicationIconImage = image
        }
    }

    /// Shows the app in the dock. The dock forgets a custom icon while the app is
    /// not in the dock, so set the icon of the service again.
    func showInDock() {
        let wasInDock = NSApp.activationPolicy() == .regular
        NSApp.setActivationPolicy(.regular)
        guard !wasInDock else { return }
        NSApp.applicationIconImage = dockIcon
        // The dock adds the tile asynchronously and can show the bundle icon first.
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.activationPolicy() == .regular else { return }
            NSApp.applicationIconImage = self.dockIcon
        }
    }
}

/// Shows SwiftUI content but lets all clicks go to the view below, the menu bar button.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Draggable title bar view overlay
struct DraggableView: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableNSView { DraggableNSView() }
    func updateNSView(_ nsView: DraggableNSView, context: Context) {}
}

final class DraggableNSView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}


// Native macOS visual effect view for title bar blur
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// (Removed custom draggable and traffic light views; using native title bar)
