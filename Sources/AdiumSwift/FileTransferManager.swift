import Foundation
import CLibpurple
import AppKit

public enum FileTransferDirection: String, Codable, CaseIterable, Sendable {
    case incoming = "incoming"
    case outgoing = "outgoing"
}

public enum FileTransferState: String, Codable, CaseIterable, Sendable {
    case pending = "pending"
    case transferring = "transferring"
    case paused = "paused"
    case completed = "completed"
    case cancelled = "cancelled"
    case failed = "failed"
}

public struct FileTransferItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    // This uses var instead of let.
    // The destroy callback clears this field when libpurple frees the PurpleXfer.
    // This stops accept/cancel buttons from targeting a freed pointer.
    public var rawPointerAddr: UInt?
    public var contactName: String
    public var filename: String
    public var localPath: String?
    public var totalBytes: Int64
    public var transferredBytes: Int64
    public var direction: FileTransferDirection
    public var state: FileTransferState
    public var startDate: Date
    public var speedBytesPerSec: Double
    
    public var progress: Double {
        guard totalBytes > 0 else { return state == .completed ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(transferredBytes) / Double(totalBytes)))
    }
    
    public var formattedSpeed: String {
        guard speedBytesPerSec > 0 else { return "-- KB/s" }
        if speedBytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", speedBytesPerSec / 1_048_576.0)
        } else {
            return String(format: "%.0f KB/s", speedBytesPerSec / 1024.0)
        }
    }
    
    public var formattedBytes: String {
        let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let transStr = ByteCountFormatter.string(fromByteCount: transferredBytes, countStyle: .file)
        return "\(transStr) / \(totalStr)"
    }
    
    public init(
        id: UUID = UUID(),
        rawPointerAddr: UInt? = nil,
        contactName: String,
        filename: String,
        localPath: String? = nil,
        totalBytes: Int64 = 0,
        transferredBytes: Int64 = 0,
        direction: FileTransferDirection = .incoming,
        state: FileTransferState = .pending,
        startDate: Date = Date(),
        speedBytesPerSec: Double = 0.0
    ) {
        self.id = id
        self.rawPointerAddr = rawPointerAddr
        self.contactName = contactName
        self.filename = filename
        self.localPath = localPath
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.direction = direction
        self.state = state
        self.startDate = startDate
        self.speedBytesPerSec = speedBytesPerSec
    }
}

@MainActor
@Observable
public final class FileTransferManager {
    public static let shared = FileTransferManager()
    
    public var transfers: [FileTransferItem] = []

    /// A local operation failure sets this message.
    /// The UI displays this instead of dropping the request.
    public private(set) var lastErrorMessage: String?

    public init() {}

    /// This dismisses the current error.
    public func clearError() {
        lastErrorMessage = nil
    }

    /// This registers callbacks from PurpleBridge to listen to file transfers.
    public func registerPurpleCallbacks() {
        adium_purple_set_xfer_callbacks(
            FileTransferManager.handleXferNewCallback,
            FileTransferManager.handleXferUpdateCallback,
            FileTransferManager.handleXferCancelCallback,
            FileTransferManager.handleXferDestroyedCallback
        )
    }

    /// This accepts an incoming file transfer and sets the download path.
    public func acceptTransfer(_ item: FileTransferItem, saveToPath: String) {
        guard let idx = transfers.firstIndex(where: { $0.id == item.id }) else { return }
        transfers[idx].localPath = saveToPath
        transfers[idx].state = .transferring

        if let rawAddr = item.rawPointerAddr, let ptr = UnsafeMutableRawPointer(bitPattern: rawAddr) {
            _ = adium_purple_xfer_accept(ptr, saveToPath)
        }
    }

    /// This cancels an active or pending file transfer.
    public func cancelTransfer(_ item: FileTransferItem) {
        guard let idx = transfers.firstIndex(where: { $0.id == item.id }) else { return }
        transfers[idx].state = .cancelled

        if let rawAddr = item.rawPointerAddr, let ptr = UnsafeMutableRawPointer(bitPattern: rawAddr) {
            _ = adium_purple_xfer_cancel(ptr)
        }
    }

    // Libpurple 2.x xfer API does not support pause.
    // A PurpleXfer only supports cancel.
    // These are no-ops that leave the state unchanged.
    // This prevents bad data in the UI.
    public func pauseTransfer(_ item: FileTransferItem) {
        #if DEBUG
        print("[FileTransferManager] pauseTransfer requested for \(item.filename), but pausing isn't supported by libpurple 2.x — ignoring")
        #endif
    }

    public func resumeTransfer(_ item: FileTransferItem) {
        #if DEBUG
        print("[FileTransferManager] resumeTransfer requested for \(item.filename), but pausing isn't supported by libpurple 2.x — ignoring")
        #endif
    }

    /// This starts an outgoing file transfer to a contact.
    /// It does not add a row.
    /// The onXferNew callback creates the row when the transfer starts.
    /// This prevents a duplicate row stuck at 0%.
    public func sendFile(to contact: Contact, at fileURL: URL) {
        guard PurpleBridgeService.shared.isLibpurpleLoaded else { return }

        guard let account = PurpleBridgeService.shared.resolveAccount(for: contact) else {
            lastErrorMessage = t("Could not send the file: no account found for \(contact.displayName)")
            return
        }

        _ = adium_purple_send_file(account.username, contact.accountProtocol.purpleProtocolID, contact.handle, fileURL.path)
    }

    /// These are handlers called from C callbacks.
    public func onXferNew(rawPointerAddr: UInt, who: String, filename: String, size: Int64, isIncoming: Bool) {
        let item = FileTransferItem(
            rawPointerAddr: rawPointerAddr,
            contactName: who,
            filename: filename,
            totalBytes: size,
            transferredBytes: 0,
            direction: isIncoming ? .incoming : .outgoing,
            state: isIncoming ? .pending : .transferring,
            startDate: Date()
        )
        transfers.append(item)
    }

    public func onXferUpdate(rawPointerAddr: UInt, bytesSent: Int64, totalBytes: Int64, status: Int32) {
        guard let idx = transfers.firstIndex(where: { $0.rawPointerAddr == rawPointerAddr }) else { return }
        // Do not let a late progress update change a cancelled transfer.
        // This prevents the state from flipping back to transferring.
        guard transfers[idx].state != .cancelled && transfers[idx].state != .failed else { return }

        let now = Date()
        let elapsed = max(0.1, now.timeIntervalSince(transfers[idx].startDate))
        let diffBytes = bytesSent - transfers[idx].transferredBytes

        transfers[idx].transferredBytes = bytesSent
        if totalBytes > 0 { transfers[idx].totalBytes = totalBytes }
        if diffBytes > 0 {
            transfers[idx].speedBytesPerSec = Double(bytesSent) / elapsed
        }

        if bytesSent >= transfers[idx].totalBytes && transfers[idx].totalBytes > 0 {
            transfers[idx].state = .completed
        } else if transfers[idx].state == .pending || transfers[idx].state == .transferring {
            transfers[idx].state = .transferring
        }
    }

    public func onXferCancel(rawPointerAddr: UInt, byLocal: Bool) {
        guard let idx = transfers.firstIndex(where: { $0.rawPointerAddr == rawPointerAddr }) else { return }
        transfers[idx].state = .cancelled
    }

    /// Libpurple is about to free the PurpleXfer for this row.
    /// This marks the row failed if the transfer is not complete.
    /// This prevents the UI from showing a stuck row.
    /// This clears rawPointerAddr so buttons stop targeting a bad pointer.
    public func onXferDestroyed(rawPointerAddr: UInt) {
        guard let idx = transfers.firstIndex(where: { $0.rawPointerAddr == rawPointerAddr }) else { return }
        if transfers[idx].state != .completed && transfers[idx].state != .cancelled && transfers[idx].state != .failed {
            transfers[idx].state = .failed
        }
        transfers[idx].rawPointerAddr = nil
    }

    // C static callbacks
    private static let handleXferNewCallback: adium_purple_on_xfer_new_cb = { xferHandle, who, filename, size, isIncoming in
        guard let xferHandle = xferHandle else { return }
        let addr = UInt(bitPattern: xferHandle)
        let wStr = who != nil ? String(cString: who!) : ""
        let fStr = filename != nil ? String(cString: filename!) : ""
        let sz = Int64(size)
        
        DispatchQueue.main.async {
            FileTransferManager.shared.onXferNew(rawPointerAddr: addr, who: wStr, filename: fStr, size: sz, isIncoming: isIncoming)
        }
    }
    
    private static let handleXferUpdateCallback: adium_purple_on_xfer_update_cb = { xferHandle, bytesSent, totalBytes, status in
        guard let xferHandle = xferHandle else { return }
        let addr = UInt(bitPattern: xferHandle)
        let bs = Int64(bytesSent)
        let tb = Int64(totalBytes)
        
        DispatchQueue.main.async {
            FileTransferManager.shared.onXferUpdate(rawPointerAddr: addr, bytesSent: bs, totalBytes: tb, status: status)
        }
    }
    
    private static let handleXferCancelCallback: adium_purple_on_xfer_cancel_cb = { xferHandle, byLocal in
        guard let xferHandle = xferHandle else { return }
        let addr = UInt(bitPattern: xferHandle)

        DispatchQueue.main.async {
            FileTransferManager.shared.onXferCancel(rawPointerAddr: addr, byLocal: byLocal)
        }
    }

    private static let handleXferDestroyedCallback: adium_purple_on_xfer_destroyed_cb = { xferHandle in
        guard let xferHandle = xferHandle else { return }
        let addr = UInt(bitPattern: xferHandle)

        DispatchQueue.main.async {
            FileTransferManager.shared.onXferDestroyed(rawPointerAddr: addr)
        }
    }
}
