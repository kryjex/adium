import Foundation
import CoreGraphics

/// This watches user idle time and switches the status to Away
/// automatically, then restores it when activity returns. The classic app
/// used AIAutomaticStatus + AdiumIdleManager; this uses CGEventSource
/// session idle times, which need no extra permissions.
@MainActor
@Observable
public final class IdleMonitor {
    public static let shared = IdleMonitor()

    private var timer: Timer?
    /// Status to restore when the user comes back. Nil while not awayed.
    private var statusBeforeAway: OnlineStatus?

    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "AdiumAutoAwayEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "AdiumAutoAwayEnabled") }
    }

    public var awayAfterMinutes: Int {
        get { UserDefaults.standard.object(forKey: "AdiumAutoAwayMinutes") as? Int ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: "AdiumAutoAwayMinutes") }
    }

    private init() {
        start()
    }

    /// This starts the periodic check. Calling it twice does nothing.
    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    /// This flips to Away after the threshold and restores afterwards.
    /// A status the user picks while awayed cancels the restore.
    public func tick() {
        guard isEnabled else { return }
        let bridge = PurpleBridgeService.shared
        let threshold = Double(max(1, awayAfterMinutes)) * 60
        let idle = Self.idleSeconds()

        if statusBeforeAway == nil {
            guard bridge.myStatus == .available, idle >= threshold else { return }
            statusBeforeAway = bridge.myStatus
            bridge.setUserStatus(.away)
        } else {
            if bridge.myStatus != .away {
                statusBeforeAway = nil
                return
            }
            if idle < threshold {
                bridge.setUserStatus(statusBeforeAway ?? .available)
                statusBeforeAway = nil
            }
        }
    }

    /// Seconds since the last local input event of any common kind.
    static func idleSeconds() -> Double {
        let watched: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseDragged,
            .rightMouseDown, .rightMouseDragged,
            .otherMouseDown, .otherMouseDragged,
            .keyDown, .scrollWheel,
        ]
        return watched.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.max() ?? 0
    }
}
