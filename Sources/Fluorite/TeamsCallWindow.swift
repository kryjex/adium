import AppKit
import WebKit
import AVFoundation

/// This detects Microsoft Teams meeting links and builds join URLs.
/// The URL construction mirrors the /call command of purple-teams.
public enum TeamsCallLink {
    private static let meetingURLRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "https://teams\\.(?:microsoft|live)\\.com/(?:l/meetup-join/|meet/)[^\\s<>\"'\\)\\]]+",
            options: [.caseInsensitive]
        )
    }()

    /// This finds the first Teams meeting link in a message text.
    /// This works on plain text and on HTML href attributes.
    public static func meetingURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = meetingURLRegex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return URL(string: String(text[matchRange]))
    }

    /// purple-teams writes these system messages when a call starts.
    /// See teams_trouter.c handling of callNotification events.
    public static func isCallEventMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "Incoming call" || trimmed == "Outgoing call"
    }

    /// Teams thread ids ("19:...@thread.v2") identify a joinable conversation.
    /// A buddy handle is not a thread. The plugin resolves it instead through the /call command.
    public static func meetingURL(forThreadHandle handle: String) -> URL? {
        guard handle.hasPrefix("19:") else { return nil }
        guard let encoded = handle.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "https://teams.microsoft.com/l/meetup-join/\(encoded)/0")
    }

    /// The app grants media capture only to Microsoft's call and auth origins.
    public static func isTrustedCallHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let trustedSuffixes = [
            "teams.microsoft.com", "teams.live.com", "microsoft.com",
            "microsoftonline.com", "live.com", "skype.com", "office.com"
        ]
        return trustedSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }
}

/// This hosts Teams calls in a WKWebView window.
/// The Teams web client handles WebRTC, signaling, and rendering.
/// Adium only manages the window, the session, and the hardware permissions.
@MainActor
public final class TeamsCallWindowController: NSObject {
    public static let shared = TeamsCallWindowController()

    private var callWindow: NSWindow?
    private var callWebView: WKWebView?
    private var popupWindows: [ObjectIdentifier: NSWindow] = [:]

    /// Teams web supports Safari. Masking as Chrome breaks WebKit feature detection.
    /// The default WKWebView agent lacks the Safari token, so Teams treats it as unsupported.
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// This opens (or reuses) the call window and loads the meeting URL.
    public func open(url: URL) {
        requestHardwareAccess()

        if let webView = callWebView, let window = callWindow {
            webView.load(URLRequest(url: url))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let webView = makeWebView(configuration: Self.makeConfiguration())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = t("Teams Video Call - Adium")
        window.contentView = webView
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.callWindow = window
        self.callWebView = webView

        webView.load(URLRequest(url: url))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // The default store persists the Microsoft login between calls.
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return configuration
    }

    private func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.safariUserAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        return webView
    }

    /// This surfaces the macOS TCC prompts before the page asks for media.
    /// Without this the in-call permission grant fails silently on first run.
    private func requestHardwareAccess() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
}

extension TeamsCallWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing == callWindow {
            // Dropping the web view stops camera and microphone capture.
            callWebView?.stopLoading()
            callWindow?.contentView = nil
            callWebView = nil
            callWindow = nil
        } else if let key = popupWindows.first(where: { $0.value == closing })?.key {
            popupWindows.removeValue(forKey: key)
        }
    }
}

extension TeamsCallWindowController: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(TeamsCallLink.isTrustedCallHost(origin.host) ? .grant : .deny)
    }

    /// Microsoft's login flow opens popup windows. Each popup gets its own child window.
    /// Create the web view with the configuration WebKit passes in.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = Self.safariUserAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = t("Sign in - Teams")
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.delegate = self

        popupWindows[ObjectIdentifier(popup)] = window
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    public func webViewDidClose(_ webView: WKWebView) {
        if let window = popupWindows.removeValue(forKey: ObjectIdentifier(webView)) {
            window.close()
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: t("OK"))
        alert.addButton(withTitle: t("Cancel"))
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

extension TeamsCallWindowController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        // The msteams:// scheme tries to open the native client. Keep the call in the web view instead.
        if url.scheme == "msteams" {
            return .cancel
        }
        return .allow
    }
}
