import SwiftUI

public struct ChatView: View {
    let contact: Contact
    @Bindable var bridge = PurpleBridgeService.shared
    @State private var messageInput: String = ""
    @State private var showParticipants: Bool = false
    @State private var showAddParticipantSheet: Bool = false
    
    public init(contact: Contact) {
        self.contact = contact
    }
    
    var currentContact: Contact {
        bridge.contacts.first(where: { $0.id == contact.id || $0.handle == contact.handle }) ?? contact
    }
    
    var messages: [ChatMessage] {
        bridge.messages(for: currentContact)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Compact Header
            HStack(spacing: 8) {
                if currentContact.isGroupChat {
                    Image(systemName: "person.3.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 13))
                } else {
                    Circle()
                        .fill(statusColor(currentContact.status))
                        .frame(width: 8, height: 8)
                }
                
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(currentContact.name)
                            .font(.system(size: 12, weight: .bold))
                        
                        if currentContact.isGroupChat {
                            Text("(\(currentContact.groupParticipants.count) participantes)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let topic = currentContact.topic, !topic.isEmpty {
                        Text(topic)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(currentContact.handle)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if currentContact.isGroupChat {
                    Button(action: { withAnimation { showParticipants.toggle() } }) {
                        Label(showParticipants ? "Ocultar Miembros" : "Ver Miembros", systemImage: "sidebar.right")
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                Label(currentContact.accountProtocol.rawValue, systemImage: currentContact.accountProtocol.iconName)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Material.bar)
            
            Divider()
            
            // Main content split: Messages + optional Participants side panel
            HStack(spacing: 0) {
                // Messages Scroll Area
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messages) { msg in
                                MessageBubble(message: msg, isGroupChat: currentContact.isGroupChat)
                                    .id(msg.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                // Group Participants Side Panel
                if currentContact.isGroupChat && showParticipants {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Participantes")
                                .font(.system(size: 11, weight: .bold))
                            Spacer()
                            Button(action: { showAddParticipantSheet = true }) {
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Añadir participante al grupo")
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        
                        Divider()
                        
                        List {
                            ForEach(currentContact.groupParticipants) { p in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(statusColor(p.status))
                                        .frame(width: 6, height: 6)
                                    
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(p.displayName)
                                            .font(.system(size: 10, weight: .medium))
                                        Text(p.handle)
                                            .font(.system(size: 8))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if let role = p.role {
                                        Text(role)
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.accentColor)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    }
                                }
                                .padding(.vertical, 2)
                                .contextMenu {
                                    Button("Eliminar del Grupo", role: .destructive) {
                                        bridge.removeGroupParticipant(contactID: currentContact.id, participantHandle: p.handle)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                    .frame(width: 170)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                }
            }
            
            Divider()
            
            // Compact Text Input
            HStack(spacing: 6) {
                Button(action: selectAndSendFile) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Enviar archivo (Transferencia de archivos)...")
                
                TextField("Escribe un mensaje...", text: $messageInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onSubmit {
                        send()
                    }
                
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderless)
                .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 320, idealWidth: 420, minHeight: 250, idealHeight: 380)
        .task(id: currentContact.id) {
            _ = bridge.messages(for: currentContact)
            bridge.markAsRead(for: currentContact.id)
        }
        .dropDestination(for: URL.self) { items, location in
            for fileURL in items {
                FileTransferManager.shared.sendFile(to: currentContact, at: fileURL)
                let fileMsg = "[Iniciada transferencia de archivo: \(fileURL.lastPathComponent)]"
                bridge.sendMessage(fileMsg, to: currentContact)
            }
            FileTransferWindowController.shared.show()
            return true
        }
        .sheet(isPresented: $showAddParticipantSheet) {
            AddParticipantSheet(groupContactID: currentContact.id, isPresented: $showAddParticipantSheet)
        }
    }
    
    private func selectAndSendFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            FileTransferManager.shared.sendFile(to: currentContact, at: url)
            let fileMsg = "[Iniciada transferencia de archivo: \(url.lastPathComponent)]"
            bridge.sendMessage(fileMsg, to: currentContact)
            FileTransferWindowController.shared.show()
        }
    }
    
    private func send() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bridge.sendMessage(trimmed, to: currentContact)
        
        let currentMsgs = bridge.messages(for: currentContact)
        ChatLogStore.shared.saveMessages(currentMsgs, for: currentContact.handle)
        
        messageInput = ""
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

struct AddParticipantSheet: View {
    let groupContactID: UUID
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var handle: String = ""
    @State private var role: String = "Miembro"
    @Bindable var bridge = PurpleBridgeService.shared
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Añadir Participante al Grupo")
                .font(.system(size: 12, weight: .bold))
            
            Form {
                TextField("Nombre del participante:", text: $name)
                    .font(.system(size: 11))
                TextField("Handle / JID / Email:", text: $handle)
                    .font(.system(size: 11))
                Picker("Rol:", selection: $role) {
                    Text("Miembro").tag("Miembro")
                    Text("Administrador").tag("Administrador")
                    Text("Propietario").tag("Propietario")
                }
                .font(.system(size: 11))
            }
            .formStyle(.grouped)
            
            HStack {
                Button("Cancelar") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Añadir") {
                    let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedHandle.isEmpty else { return }
                    let pName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedHandle : name
                    let participant = GroupParticipant(name: pName, handle: trimmedHandle, status: .available, role: role)
                    bridge.addGroupParticipant(contactID: groupContactID, participant: participant)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320, height: 220)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var isGroupChat: Bool = false
    
    var body: some View {
        HStack {
            if message.isFromMe { Spacer() }
            
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if isGroupChat && !message.isFromMe {
                    Text(message.senderName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                
                RichMessageView(rawText: message.text, isFromMe: message.isFromMe)
                    .font(.system(size: 11))
                    .foregroundColor(message.isFromMe ? .white : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(message.isFromMe ? Color.accentColor : Color.secondary.opacity(0.18))
                    )
                
                Text(message.timestamp, style: .time)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            
            if !message.isFromMe { Spacer() }
        }
    }
}
