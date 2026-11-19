import SwiftUI
import WebKit

struct ServiceWebView: NSViewRepresentable {
    let url: URL?
    @ObservedObject var playerState: PlayerState
    @Binding var webView: WKWebView?
    let popupCoordinator: WebPopupCoordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
        var parent: ServiceWebView
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

        init(_ parent: ServiceWebView) { self.parent = parent }

        static let noPasskeysScript = """
        (function() {
            if (location.hostname !== 'accounts.google.com') return;
            try { delete window.PublicKeyCredential; } catch (e) {}
            try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }); } catch (e) {}
        })();
        """

        private var consoleScript: String {
            """
            (function(){
              function toMessage(args){
                try { return Array.from(args).map(function(a){ return (typeof a === 'object') ? JSON.stringify(a) : String(a); }).join(' '); }
                catch(e){ return '<log error>'; }
              }
              ['log','warn','error','info'].forEach(function(level){
                var orig = console[level];
                console[level] = function(){
                  try { var msg = toMessage(arguments);
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.consoleLog) {
                      window.webkit.messageHandlers.consoleLog.postMessage('['+level.toUpperCase()+'] '+msg);
                    }
                  } catch(e){}
                  try { orig && orig.apply(console, arguments); } catch(e){}
                };
              });
            })();
            """
        }

        // MARK: Title bar fill

        private var edgeTimer: Timer?
        private var lastEdgeSignature: Data?

        /// The title bar above the page shows the top row of the page's pixels, stretched.
        /// This matches any page: plain colors, gradients and background images.
        func startEdgeSampling(_ webView: WKWebView) {
            stopEdgeSampling()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.sampleEdge(of: webView)
            }
            RunLoop.main.add(timer, forMode: .common)
            edgeTimer = timer
        }

        func stopEdgeSampling() {
            edgeTimer?.invalidate()
            edgeTimer = nil
        }

        private func sampleEdge(of webView: WKWebView) {
            // Only while the window shows, and never while the page is still empty.
            guard let window = webView.window, window.isVisible, window.occlusionState.contains(.visible),
                  webView.bounds.width > 0, !webView.isLoading || webView.estimatedProgress > 0.5
            else { return }
            let config = WKSnapshotConfiguration()
            // WKWebView is flipped: y = 0 is the top edge of the page.
            config.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: 1)
            config.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 320)))
            webView.takeSnapshot(with: config) { [weak self] image, _ in
                guard let self, let image,
                      let signature = image.tiffRepresentation
                else { return }
                guard signature != self.lastEdgeSignature else { return }
                self.lastEdgeSignature = signature
                withAnimation(.easeInOut(duration: 0.3)) { self.parent.playerState.pageEdge = image }
            }
        }

        func prepare(_ configuration: WKWebViewConfiguration) {
            configuration.websiteDataStore = .default()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            configuration.userContentController.add(self, name: "mediaSession")
            #if DEBUG
            // Page console output goes to stdout only in debug builds: it can contain account details.
            configuration.userContentController.add(self, name: "consoleLog")
            let console = WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            configuration.userContentController.addUserScript(console)
            #endif
            // Streamlet cannot use passkeys: the app does not have the entitlement for
            // WebAuthn. Google then fails with "Make sure Bluetooth is on". Without the API,
            // Google offers the password sign-in at once.
            let noPasskeys = WKUserScript(source: Self.noPasskeysScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            configuration.userContentController.addUserScript(noPasskeys)
            // Inject into all frames so we catch players living in iframes (e.g., Deezer)
            let ms = WKUserScript(source: MediaSessionBridge.mediaSessionObserverScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            configuration.userContentController.addUserScript(ms)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popup.customUserAgent = userAgent
            parent.popupCoordinator.addWebView(popup, title: "Popup", openInNewWindow: true, windowFeatures: windowFeatures)
            return popup
        }
        func webViewDidClose(_ webView: WKWebView) { parent.popupCoordinator.closeWindow(for: webView) }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "mediaSession" {
                if let body = message.body as? [String: Any] {
                    let frame = message.frameInfo
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        (self.parent.playerState.webViewControl as? WebViewController)?.noteMessage(body, from: frame)
                        self.parent.playerState.updateFromMediaSession(body)
                    }
                }
            } else if message.name == "consoleLog" {
                #if DEBUG
                if let log = message.body as? String { print(log) }
                #endif
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated {
                if let request = navigationAction.request as URLRequest? {
                    webView.load(request)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if webView === parent.webView, let url = webView.url {
                parent.playerState.noteServiceLocation(url)
            }
            webView.evaluateJavaScript("document.title") { [weak self] (result, _) in
                guard let self = self, let title = result as? String, !title.isEmpty else { return }
                DispatchQueue.main.async { self.parent.popupCoordinator.updateWindowTitle(for: webView, title: title) }
            }
            
            // Extract high-res favicon from DOM
            let faviconScript = """
            (function() {
                // Look for Apple touch icons (highest quality)
                const appleTouchIcon = document.querySelector('link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]');
                if (appleTouchIcon && appleTouchIcon.href) {
                    return appleTouchIcon.href;
                }
                
                // Look for high-res favicon
                const highResIcon = document.querySelector('link[rel="icon"][sizes*="192"], link[rel="icon"][sizes*="180"], link[rel="icon"][sizes*="144"], link[rel="icon"][sizes*="96"]');
                if (highResIcon && highResIcon.href) {
                    return highResIcon.href;
                }
                
                // Look for any favicon
                const favicon = document.querySelector('link[rel="icon"], link[rel="shortcut icon"]');
                if (favicon && favicon.href) {
                    return favicon.href;
                }
                
                // Fallback to /favicon.ico
                return window.location.origin + '/favicon.ico';
            })();
            """
            
            webView.evaluateJavaScript(faviconScript) { [weak self] (result, _) in
                if let faviconURL = result as? String {
                    DispatchQueue.main.async { 
                        self?.parent.playerState.serviceFaviconURL = faviconURL
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        context.coordinator.prepare(configuration)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.customUserAgent = context.coordinator.userAgent
        DispatchQueue.main.async { self.webView = view }
        if let url = url { view.load(URLRequest(url: url)) }
        context.coordinator.startEdgeSampling(view)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = view.window {
                window.makeFirstResponder(view)
                window.makeKeyAndOrderFront(nil)
            }
        }
        
        return view
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

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopEdgeSampling()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "mediaSession")
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "consoleLog")
        nsView.configuration.userContentController.removeAllUserScripts()
    }
}

/// Sends player commands to the page. Each command goes to the frame that can act on it:
/// the frame with the Media Session handlers, the frame with the playing element, or the
/// frame with the service controls. The next frame is tried only when one reports failure,
/// so a command never runs twice.
final class WebViewController: WebViewControl {
    weak var webView: WKWebView? {
        didSet {
            if webView !== oldValue { forgetFrames() }
        }
    }

    private var sessionFrame: WKFrameInfo?
    private var mediaFrame: WKFrameInfo?
    private var controlsFrame: WKFrameInfo?

    private func forgetFrames() {
        sessionFrame = nil
        mediaFrame = nil
        controlsFrame = nil
    }

    /// Remembers which frame sent what, so commands can go back to that frame.
    func noteMessage(_ body: [String: Any], from frame: WKFrameInfo) {
        if body["reset"] != nil, frame.isMainFrame { forgetFrames() }
        if let handlers = body["handlers"] as? [Any], !handlers.isEmpty { sessionFrame = frame }
        if (body["isPlaying"] as? Bool) == true { mediaFrame = frame }
        if body["controls"] != nil { controlsFrame = frame }
    }

    func send(_ command: PlayerCommand) {
        let name: String
        var arg: Any = NSNull()
        let candidates: [WKFrameInfo?]
        switch command {
        case .playPause(let isPlaying):
            name = "playpause"; arg = isPlaying
            candidates = [sessionFrame, mediaFrame, nil]
        case .pause:
            name = "pause"
            candidates = [sessionFrame, mediaFrame, nil]
        case .next:
            name = "next"
            candidates = [sessionFrame, nil]
        case .previous:
            name = "previous"
            candidates = [sessionFrame, nil]
        case .seek(let time):
            guard time.isFinite, time >= 0 else { return }
            name = "seek"; arg = time
            candidates = [sessionFrame, mediaFrame, nil]
        case .shuffle:
            name = "shuffle"
            candidates = [controlsFrame, nil]
        case .repeatMode:
            name = "repeat"
            candidates = [controlsFrame, nil]
        case .like:
            name = "like"
            candidates = [controlsFrame, nil]
        }
        run(name, arg: arg, in: candidates[...])
    }

    /// Largest data URL accepted for one video picture.
    private static let maxFrameLength = 1_500_000
    private static let framePrefix = "data:image/jpeg;base64,"

    /// Asks the frame with the playing element for the current video picture.
    func videoFrame(maxWidth: Int, completion: @escaping (NSImage?) -> Void) {
        guard let webView else { return completion(nil) }
        webView.callAsyncJavaScript(
            "return window.__streamletVideoFrame ? window.__streamletVideoFrame(w) : null;",
            arguments: ["w": maxWidth],
            in: mediaFrame,
            in: .page
        ) { result in
            // The picture comes from the page: accept only a JPEG data URL of limited size.
            guard let text = (try? result.get()) as? String,
                  text.count <= Self.maxFrameLength,
                  text.hasPrefix(Self.framePrefix),
                  let data = Data(base64Encoded: String(text.dropFirst(Self.framePrefix.count))),
                  let image = NSImage(data: data)
            else { return completion(nil) }
            completion(image)
        }
    }

    private func run(_ name: String, arg: Any, in candidates: ArraySlice<WKFrameInfo?>) {
        guard let webView, let frame = candidates.first else {
            print("Streamlet: command '\(name)' had no effect")
            return
        }
        webView.callAsyncJavaScript(
            "return window.__streamletCommand ? window.__streamletCommand(cmd, arg) : { success: false };",
            arguments: ["cmd": name, "arg": arg],
            in: frame,
            in: .page
        ) { [weak self] result in
            let succeeded = ((try? result.get()) as? [String: Any])?["success"] as? Bool ?? false
            if !succeeded { self?.run(name, arg: arg, in: candidates.dropFirst()) }
        }
    }
}
