import SwiftUI

class WindowManager: ObservableObject {
    static let shared = WindowManager()
    
    func openSettings() {
        if let existingWindow = NSApp.windows.first(where: { $0.title == "Streamlet Settings" }) {
            existingWindow.makeKeyAndOrderFront(nil)
        } else {
            // Trigger opening the settings window
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}