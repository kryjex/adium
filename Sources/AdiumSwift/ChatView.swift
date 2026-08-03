import SwiftUI

public struct ChatView: View {
    let contact: Contact
    @Bindable var bridge = PurpleBridgeService.shared
    @State private var messageInput: String = ""
    
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
                Circle()
                    .fill(statusColor(currentContact.status))
                    .frame(width: 8, height: 8)
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(currentContact.name)
                        .font(.system(size: 12, weight: .bold))
                    Text(currentContact.handle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
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
            
            // Messages Scroll Area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
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
            
            Divider()
            
            // Compact Text Input
            HStack(spacing: 6) {
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
        .frame(minWidth: 320, idealWidth: 400, minHeight: 250, idealHeight: 350)
        .task(id: currentContact.id) {
            _ = bridge.messages(for: currentContact)
        }
        .dropDestination(for: URL.self) { items, location in
            for fileURL in items {
                let fileMsg = "[Adjunto: \(fileURL.lastPathComponent) - Transferencia de archivos no disponible en este protocolo]"
                bridge.sendMessage(fileMsg, to: currentContact)
            }
            return true
        }
    }
    
    private func send() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bridge.sendMessage(trimmed, to: currentContact)
        NotificationService.shared.playSendSound()
        
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

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isFromMe { Spacer() }
            
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                Text(message.text)
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
