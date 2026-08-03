import SwiftUI
import AppKit

public extension Notification.Name {
    static let focusContactSearch = Notification.Name("focusContactSearch")
    static let openNewConversation = Notification.Name("openNewConversation")
    static let openAddAccount = Notification.Name("openAddAccount")
    static let openTranscriptViewer = Notification.Name("openTranscriptViewer")
    static let openFileTransfers = Notification.Name("openFileTransfers")
    static let closeActiveTab = Notification.Name("closeActiveTab")
}

@main
struct AdiumSwiftApp: App {
    @Bindable var bridge = PurpleBridgeService.shared
    @State private var selectedContactID: UUID?
    
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        PurpleBridgeService.shared.initializeLibpurpleCore()
        FileTransferManager.shared.registerPurpleCallbacks()
    }
    
    var body: some Scene {
        WindowGroup("Adium (Lista de Contactos)") {
            NavigationSplitView {
                ContactListView(selectedContactID: $selectedContactID)
                    .navigationTitle("Adium")
            } detail: {
                TabbedChatContainerView()
            }
            .onChange(of: selectedContactID) { _, newID in
                if let id = newID {
                    bridge.openTab(for: id)
                }
            }
            .frame(minWidth: 600, minHeight: 420)
            .task {
                await MacOSContactsService.shared.autoLinkAllContacts()
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        
        Settings {
            PreferencesView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nueva Conversación") {
                    NotificationCenter.default.post(name: .openNewConversation, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            
            CommandGroup(after: .newItem) {
                Button("Añadir Cuenta...") {
                    NotificationCenter.default.post(name: .openAddAccount, object: nil)
                }
                .keyboardShortcut("A", modifiers: [.command, .shift])
            }
            
            CommandGroup(replacing: .textEditing) {
                Button("Buscar Contactos") {
                    NotificationCenter.default.post(name: .focusContactSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
            
            CommandMenu("Transcripciones") {
                Button("Visor de Transcripciones (⌘⌥T)") {
                    TranscriptViewerWindowController.shared.show()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                
                Button("Visor de Transcripciones (⌘⇧T)") {
                    TranscriptViewerWindowController.shared.show()
                }
                .keyboardShortcut("T", modifiers: [.command, .shift])
            }
            
            CommandGroup(after: .windowList) {
                Button("Transferencias de Archivos") {
                    FileTransferWindowController.shared.show()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
            }

            CommandGroup(after: .windowList) {
                // Only claims ⌘W while a tab is open; otherwise it's disabled so the
                // system's standard "Close Window" item (also ⌘W) handles the window.
                Button("Cerrar Pestaña") {
                    if let activeID = bridge.activeTabID {
                        bridge.closeTab(activeID)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(bridge.activeTabID == nil)
            }
        }
    }
}

public struct TabbedChatContainerView: View {
    @Bindable var bridge = PurpleBridgeService.shared
    @State private var showJoinGroupSheet: Bool = false
    
    var activeContact: Contact? {
        guard let id = bridge.activeTabID else { return nil }
        return bridge.contacts.first(where: { $0.id == id })
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Tab Bar
            if !bridge.openTabIDs.isEmpty {
                HStack(spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(bridge.openTabIDs, id: \.self) { tabID in
                                if let contact = bridge.contacts.first(where: { $0.id == tabID }) {
                                    ChatTabItemView(
                                        contact: contact,
                                        isActive: bridge.activeTabID == tabID,
                                        unreadCount: bridge.unreadCounts[tabID] ?? 0,
                                        onSelect: { bridge.setActiveTab(tabID) },
                                        onClose: { bridge.closeTab(tabID) }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    
                    Spacer()
                    
                    Button(action: { showJoinGroupSheet = true }) {
                        Label("Unirse a Grupo", systemImage: "person.3.badge.plus")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.trailing, 6)
                    .help("Unirse a un chat de grupo o canal (MUC)")
                }
                .background(Material.bar)
                
                Divider()
            }
            
            // Active Tab Content
            if let contact = activeContact {
                ChatView(contact: contact)
                    .id(contact.id)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor.opacity(0.8))
                    
                    Text("AdiumSwift")
                        .font(.system(size: 16, weight: .bold))
                    
                    Text("Selecciona un contacto de la lista o abre un chat de grupo para iniciar una conversación en pestañas.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    Button(action: { showJoinGroupSheet = true }) {
                        Label("Unirse a Chat Grupal / MUC", systemImage: "person.3.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .sheet(isPresented: $showJoinGroupSheet) {
            JoinGroupChatSheet(isPresented: $showJoinGroupSheet)
        }
    }
}

struct ChatTabItemView: View {
    let contact: Contact
    let isActive: Bool
    let unreadCount: Int
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 6) {
            if contact.isGroupChat {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 9))
                    .foregroundColor(isActive ? .accentColor : .secondary)
            } else {
                Circle()
                    .fill(statusColor(contact.status))
                    .frame(width: 6, height: 6)
            }
            
            Text(contact.displayName)
                .font(.system(size: 11, weight: isActive ? .bold : .regular))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)
            
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
            }
            
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(2)
                    .background(Circle().fill(Color.secondary.opacity(isHovered ? 0.3 : 0.0)))
            }
            .buttonStyle(.plain)
            .help("Cerrar pestaña (⌘W)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                .shadow(color: isActive ? Color.black.opacity(0.1) : Color.clear, radius: 1, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hover in
            isHovered = hover
        }
    }
    
    private func statusColor(_ status: OnlineStatus) -> Color {
        switch status {
        case .available: return .green
        case .away: return .yellow
        case .busy: return .red
        case .offline: return .gray
        }
    }
}

struct JoinGroupChatSheet: View {
    @Binding var isPresented: Bool
    @Bindable var bridge = PurpleBridgeService.shared
    @State private var channelName: String = ""
    @State private var topic: String = ""
    @State private var selectedAccountID: UUID?
    
    var selectedAccount: Account? {
        if let id = selectedAccountID {
            return bridge.accounts.first(where: { $0.id == id })
        }
        return bridge.accounts.first
    }
    
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("Unirse a Chat Grupal / Canal (MUC)")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
            }
            
            Form {
                if bridge.accounts.count > 1 {
                    Picker("Cuenta:", selection: $selectedAccountID) {
                        ForEach(bridge.accounts) { acc in
                            Text("\(acc.username) (\(acc.accountProtocol.rawValue))")
                                .tag(Optional(acc.id))
                        }
                    }
                    .font(.system(size: 11))
                }
                
                TextField("Nombre del Canal / Grupo:", text: $channelName)
                    .font(.system(size: 11))
                
                TextField("Tema / Descripción (opcional):", text: $topic)
                    .font(.system(size: 11))
            }
            .formStyle(.grouped)
            
            HStack {
                Button("Cancelar") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Unirse al Grupo") {
                    let trimmed = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let acc = selectedAccount else { return }
                    bridge.joinGroupChat(channelName: trimmed, account: acc, topic: topic.isEmpty ? nil : topic)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedAccount == nil)
            }
        }
        .padding(16)
        .frame(width: 380, height: 250)
        .onAppear {
            selectedAccountID = bridge.accounts.first?.id
        }
    }
}
