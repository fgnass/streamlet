import SwiftUI
import WebKit

struct StreamingContentView: View {
    @ObservedObject var playerState: PlayerState
    var onWebViewChange: (WKWebView?) -> Void
    @State private var webView: WKWebView? = nil
    @StateObject private var popupCoordinator = WebPopupCoordinator()

    var body: some View {
        ZStack {
            // Base content
            Group {
                switch playerState.dataSource {
                case .mock:
                    ServiceChooserView(playerState: playerState)
                        .ignoresSafeArea()
                case .webService(let urlString):
                    if let url = URL(string: urlString) {
                        ServiceWebView(
                            url: url,
                            playerState: playerState,
                            webView: Binding(
                                get: { webView },
                                set: { newValue in
                                    webView = newValue
                                    onWebViewChange(newValue)
                                }
                            ),
                            popupCoordinator: popupCoordinator
                        )
                        .id(urlString) // ensure a fresh WKWebView on URL change
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // The page starts below the title bar: the title bar takes the clicks
                        // there (to drag the window), so the page could not get them.
                        // The title bar continues the top edge of the page.
                        .background(
                            ZStack {
                                Color(nsColor: .windowBackgroundColor)
                                if let edge = playerState.pageEdge {
                                    Image(nsImage: edge)
                                        .resizable()
                                        .interpolation(.medium)
                                }
                            }
                            .ignoresSafeArea()
                        )
                    } else {
                        ServiceChooserView(playerState: playerState)
                            .ignoresSafeArea()
                    }
                }
            }

            // Overlay chooser when changing service while keeping current webview alive
            if playerState.isShowingServiceChooserOverlay {
                ServiceChooserView(playerState: playerState)
            }

            // Popups are managed by WebPopupCoordinator like in example.swift
        }
        .onChange(of: playerState.dataSource) { _ in
            // Try to pause via media session first
            playerState.webViewControl?.send(.pause)
            // Then pause and tear down the old webview explicitly before switching
            webView?.evaluateJavaScript("(() => { try { document.querySelectorAll('audio,video').forEach(el => el.pause()); } catch (e) {} return true; })();", completionHandler: nil)
            webView?.stopLoading()
            // Close any active popup panels
            popupCoordinator.closeAll()
            onWebViewChange(nil)
            webView = nil
        }
    }
}
