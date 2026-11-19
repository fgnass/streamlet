import AppKit
import SwiftUI
import WebKit

final class WebPopupCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    @Published var webViews: [WebViewEntry] = []
    private var windows: [UUID: NSWindow] = [:]
    private var closing: Set<UUID> = []

    func addWebView(
        _ webView: WKWebView,
        title: String = "New Window",
        openInNewWindow: Bool = false,
        windowFeatures: WKWindowFeatures? = nil
    ) {
        let entry = WebViewEntry(webView: webView, title: title)
        webViews.append(entry)

        if openInNewWindow { 
            openWindow(for: entry, features: windowFeatures) 
        }

        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let window = webView.window ?? self.windows[entry.id] {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(webView)
            }
        }

        objectWillChange.send()
    }

    func updateWindowTitle(for webView: WKWebView, title: String) {
        if let entry = webViews.first(where: { $0.webView === webView }) {
            windows[entry.id]?.title = title
        }
    }

    func closeWindow(for webView: WKWebView) {
        guard let entry = webViews.first(where: { $0.webView === webView }) else { return }
        if closing.contains(entry.id) { return }
        closing.insert(entry.id)
        if let window = windows[entry.id] {
            window.animationBehavior = .none
            window.orderOut(nil)
            DispatchQueue.main.async { [weak self] in
                if let self = self, let win = self.windows[entry.id] {
                    win.close()
                }
            }
        } else {
            remove(entry)
        }
    }

    func closeAll() {
        for entry in webViews {
            if let window = windows[entry.id] {
                window.animationBehavior = .none
                window.orderOut(nil)
                DispatchQueue.main.async { [weak window] in window?.close() }
            }
        }
        windows.removeAll()
        webViews.removeAll()
        closing.removeAll()
    }

    private func remove(_ entry: WebViewEntry) {
        windows.removeValue(forKey: entry.id)
        webViews.removeAll { $0.id == entry.id }
        closing.remove(entry.id)
    }

    private func openWindow(for entry: WebViewEntry, features: WKWindowFeatures?) {
        let defaultSize = CGSize(width: 900, height: 600)
        var size = defaultSize
        if let w = features?.width?.doubleValue, w > 0 { size.width = CGFloat(w) }
        if let h = features?.height?.doubleValue, h > 0 { size.height = CGFloat(h) }

        let allowsResizing = features?.allowsResizing?.boolValue ?? true
        var style: NSWindow.StyleMask = [.titled, .closable]
        if allowsResizing { style.insert(.resizable) }
        style.insert(.utilityWindow)

        let origin = NSPoint(x: CGFloat(features?.x?.doubleValue ?? 120), y: CGFloat(features?.y?.doubleValue ?? 120))
        let rect = NSRect(origin: origin, size: size)

        let panel = NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        panel.title = entry.title
        panel.delegate = self
        panel.isFloatingPanel = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none

        let popupWebView = PopupWebView(webView: entry.webView)
        let hostingView = NSHostingView(rootView: popupWebView)
        panel.contentView = hostingView

        windows[entry.id] = panel
        NSApp.setActivationPolicy(.regular)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(entry.webView)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let (id, _) = webViews.compactMap({ w in windows[w.id] == window ? (w.id, w) : nil }).first {
            windows.removeValue(forKey: id)
            webViews.removeAll { $0.id == id }
            closing.remove(id)
        }
    }
}

struct WebViewEntry: Identifiable {
    let id = UUID()
    let webView: WKWebView
    var title: String
}

struct PopupWebView: NSViewRepresentable {
    let webView: WKWebView
    
    func makeNSView(context: Context) -> WKWebView {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = webView.window {
                window.makeFirstResponder(webView)
                window.makeKeyAndOrderFront(nil)
            }
        }
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let window = nsView.window {
                if window.firstResponder != nsView {
                    window.makeFirstResponder(nsView)
                    nsView.becomeFirstResponder()
                }
            }
        }
    }
}
