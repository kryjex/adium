import SwiftUI
import AppKit

@MainActor
public final class FileTransferWindowController: NSObject, NSWindowDelegate {
    public static let shared = FileTransferWindowController()
    
    private var window: NSWindow?
    
    public override init() {
        super.init()
    }
    
    public func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = FileTransferView()
        let hostingController = NSHostingController(rootView: contentView)
        
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.center()
        newWindow.title = t("File Transfers - Fluorite")
        newWindow.contentViewController = hostingController
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func windowWillClose(_ notification: Notification) {
        self.window = nil
    }

    public func close() {
        window?.close()
    }
}
