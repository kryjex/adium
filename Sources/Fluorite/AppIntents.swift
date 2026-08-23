import Foundation
import AppIntents

/// These intents expose the classic scripting surface (send message,
/// set status, get contacts) through App Intents instead of an .sdef.
@available(macOS 14, *)
struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription("Sends a chat message to a contact matched by display name.")

    @Parameter(title: "Contact")
    var contactName: String

    @Parameter(title: "Message")
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let bridge = PurpleBridgeService.shared
        guard let contact = bridge.contacts.first(where: {
            $0.displayName.localizedCaseInsensitiveCompare(contactName) == .orderedSame
        }) ?? bridge.contacts.first(where: {
            $0.displayName.localizedCaseInsensitiveContains(contactName)
        }) else {
            return .result(dialog: "No contact named \(contactName).")
        }
        bridge.sendMessage(message, to: contact)
        return .result(dialog: "Message sent to \(contact.displayName).")
    }
}

@available(macOS 14, *)
enum StatusOption: String, AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Status")
    static let caseDisplayRepresentations: [StatusOption: DisplayRepresentation] = [
        .available: .init(title: "Available"),
        .away: .init(title: "Away"),
        .busy: .init(title: "Busy"),
        .offline: .init(title: "Offline"),
    ]

    case available
    case away
    case busy
    case offline

    var onlineStatus: OnlineStatus {
        switch self {
        case .available: return .available
        case .away: return .away
        case .busy: return .busy
        case .offline: return .offline
        }
    }
}

@available(macOS 14, *)
struct SetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Status"
    static let description = IntentDescription("Changes the user's visible status.")

    @Parameter(title: "Status")
    var status: StatusOption

    @MainActor
    func perform() async throws -> some IntentResult {
        PurpleBridgeService.shared.setUserStatus(status.onlineStatus)
        return .result()
    }
}

@available(macOS 14, *)
struct GetContactsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Contacts"
    static let description = IntentDescription("Returns every known contact as \"name — protocol\".")

    @MainActor
    func perform() async throws -> some ReturnsValue<[String]> & ProvidesDialog {
        let entries = PurpleBridgeService.shared.contacts
            .map { "\($0.displayName) — \($0.accountProtocol.rawValue)" }
            .sorted()
        return .result(value: entries, dialog: "\(entries.count) contacts")
    }
}
