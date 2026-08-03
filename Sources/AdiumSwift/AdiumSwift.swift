import SwiftUI
import AppKit

@main
struct AdiumSwiftApp: App {
    @State private var bridge = PurpleBridgeService.shared
    @State private var selectedContactID: UUID?
    
    var selectedContact: Contact? {
        guard let id = selectedContactID else { return nil }
        return bridge.contacts.first(where: { $0.id == id })
    }
    
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        PurpleBridgeService.shared.initializeLibpurpleCore()
    }
    
    var body: some Scene {
        WindowGroup("Adium (Lista de Contactos)") {
            NavigationSplitView {
                ContactListView(selectedContactID: $selectedContactID)
                    .navigationTitle("Adium")
            } detail: {
                if let contact = selectedContact {
                    ChatView(contact: contact)
                } else {
                    ContentUnavailableView(
                        "Selecciona un contacto",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Elige un contacto para comenzar a chatear.")
                    )
                }
            }
            .frame(minWidth: 550, minHeight: 400)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        
        Settings {
            PreferencesView()
        }
    }
}
