import UIKit

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

/// Posts .deviceDidShake on a physical shake gesture. SwiftUI has no shake API of
/// its own — the standard approach is overriding motionEnded on the app's actual
/// UIWindow, which only receives motion events when it's the first responder's
/// window (see SceneDelegate, which uses this in place of a plain UIWindow).
final class ShakeDetectingWindow: UIWindow {
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
