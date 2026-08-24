import Foundation
import Contacts
import AppKit

@MainActor
public final class MacOSContactsService {
    public static let shared = MacOSContactsService()
    
    private let contactStore = CNContactStore()
    
    public init() {}
    
    /// This requests user authorization to access the macOS Contacts address book.
    public func requestAccess() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            do {
                return try await contactStore.requestAccess(for: .contacts)
            } catch {
                print("[MacOSContactsService] Failed to request contacts access: \(error)")
                return false
            }
        default:
            return false
        }
    }
    
    /// This searches for a matching CNContact by email address or full name.
    ///
    /// The email match is exact.
    /// The name match is a fuzzy search. This search can return several people with the same first name.
    /// The name fallback only returns a result when exactly one contact matches the full name exactly.
    /// This prevents linking to the wrong person.
    public func findMatchingContact(email: String?, name: String?) -> CNContact? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return nil
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        // 1. This matches by email address.
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty, email.contains("@") {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            if let matched = (try? contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch))?.first {
                return matched
            }
        }

        // 2. This matches by name.
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let predicate = CNContact.predicateForContacts(matchingName: name)
            if let candidates = try? contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch) {
                let exactMatches = candidates.filter { candidate in
                    guard let fullName = CNContactFormatter.string(from: candidate, style: .fullName) else {
                        return false
                    }
                    return fullName.caseInsensitiveCompare(name) == .orderedSame
                }
                if exactMatches.count == 1 {
                    return exactMatches[0]
                }
            }
        }

        return nil
    }

    /// This links a Fluorite contact with the macOS address book. This adds the name and profile avatar.
    /// This does not overwrite a local alias.
    /// This does not replace an existing avatar.
    public func linkContact(_ contact: Contact) -> Contact {
        var updated = contact

        guard let cnContact = findMatchingContact(email: contact.handle, name: contact.name) else {
            return updated
        }

        let hasUserAlias = !(contact.alias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !hasUserAlias {
            let fullName = CNContactFormatter.string(from: cnContact, style: .fullName)
            if let fullName = fullName, !fullName.trimmingCharacters(in: .whitespaces).isEmpty {
                updated.name = fullName
            }
        }

        if updated.avatarData == nil, let imageData = cnContact.imageData ?? cnContact.thumbnailImageData {
            updated.avatarData = imageData
        }

        return updated
    }
    
    /// This links all Fluorite contacts with the macOS address book.
    public func autoLinkAllContacts() async {
        let hasAccess = await requestAccess()
        guard hasAccess else { return }
        
        let bridge = PurpleBridgeService.shared
        for idx in bridge.contacts.indices {
            let original = bridge.contacts[idx]
            let linked = linkContact(original)
            if linked.name != original.name || linked.avatarData != original.avatarData {
                bridge.contacts[idx] = linked
            }
        }
        bridge.saveContactsToDefaults()
    }
}
