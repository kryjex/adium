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
        // The filter also hides metadata blobs stored by older versions.
        bridge.messages(for: currentContact).filter { !$0.isMeetingMetadataEvent }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if currentContact.isGroupChat {
                    Image(systemName: "person.3.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(statusColor(currentContact.status))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(statusLabel(currentContact.status))
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(currentContact.name)
                            .font(.system(size: 12, weight: .bold))

                        if currentContact.isGroupChat {
                            Text(t("(\(currentContact.groupParticipants.count) participants)"))
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

                if currentContact.accountProtocol == .teams {
                    Button(action: { bridge.startTeamsCall(for: currentContact) }) {
                        Label(t("Call"), systemImage: "video.fill")
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(t("Teams video call (opens inside Adium)"))
                }

                if currentContact.isGroupChat {
                    Button(action: { withAnimation { showParticipants.toggle() } }) {
                        Label(showParticipants ? t("Hide Members") : t("Show Members"), systemImage: "sidebar.right")
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
            
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                                if index == 0 || !Calendar.current.isDate(msg.timestamp, inSameDayAs: messages[index - 1].timestamp) {
                                    DaySeparator(date: msg.timestamp)
                                }
                                MessageBubble(message: msg, isGroupChat: currentContact.isGroupChat, contact: currentContact)
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
                
                if currentContact.isGroupChat && showParticipants {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(t("Participants"))
                                .font(.system(size: 11, weight: .bold))
                            Spacer()
                            Button(action: { showAddParticipantSheet = true }) {
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help(t("Add participant to the group"))
                            .accessibilityLabel(t("Add participant"))
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
                                        .accessibilityLabel(statusLabel(p.status))

                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(p.displayName)
                                            .font(.system(size: 10, weight: .medium))
                                        Text(p.handle)
                                            .font(.system(size: 8))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if let role = p.role {
                                        Text(roleLabel(role))
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.accentColor)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    }
                                }
                                .padding(.vertical, 2)
                                .contextMenu {
                                    Button(t("Remove from Group"), role: .destructive) {
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
            
            HStack(spacing: 6) {
                Button(action: selectAndSendFile) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(t("Send a file (File transfer)..."))
                .accessibilityLabel(t("Send a file"))

                TextField(t("Type a message..."), text: $messageInput)
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
                .accessibilityLabel(t("Send message"))
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
                let fileMsg = t("[File transfer started: \(fileURL.lastPathComponent)]")
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
            let fileMsg = t("[File transfer started: \(url.lastPathComponent)]")
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

/// This returns the localized status name for accessibility.
func statusLabel(_ status: OnlineStatus) -> String {
    switch status {
    case .available: return t("Available")
    case .away: return t("Away")
    case .busy: return t("Busy")
    case .offline: return t("Offline")
    }
}

/// This maps a stored role id to its localized name.
/// Unknown ids display as-is; protocols can report their own roles.
func roleLabel(_ role: String) -> String {
    switch role {
    case "owner": return t("Owner")
    case "admin": return t("Administrator")
    case "member": return t("Member")
    default: return role
    }
}

struct AddParticipantSheet: View {
    let groupContactID: UUID
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var handle: String = ""
    @State private var role: String = "member"
    @Bindable var bridge = PurpleBridgeService.shared
    
    var body: some View {
        VStack(spacing: 12) {
            Text(t("Add Participant to the Group"))
                .font(.system(size: 12, weight: .bold))

            Form {
                TextField(t("Participant name:"), text: $name)
                    .font(.system(size: 11))
                TextField(t("Handle / JID / Email:"), text: $handle)
                    .font(.system(size: 11))
                // The tag values persist in GroupParticipant.role. Keep them stable.
                Picker(t("Role:"), selection: $role) {
                    Text(t("Member")).tag("member")
                    Text(t("Administrator")).tag("admin")
                    Text(t("Owner")).tag("owner")
                }
                .font(.system(size: 11))
            }
            .formStyle(.grouped)

            HStack {
                Button(t("Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Add")) {
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

/// A centered day label between messages of different calendar days.
struct DaySeparator: View {
    let date: Date

    private static let formatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = AppLanguage.locale
        fmt.dateStyle = .full
        fmt.timeStyle = .none
        return fmt
    }()

    private var label: String {
        if Calendar.current.isDateInToday(date) { return t("Today") }
        if Calendar.current.isDateInYesterday(date) { return t("Yesterday") }
        return Self.formatter.string(from: date)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            VStack { Divider() }
        }
        .padding(.vertical, 4)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var isGroupChat: Bool = false
    var contact: Contact? = nil

    /// A meeting link in the text joins directly.
    private var meetingURL: URL? {
        TeamsCallLink.meetingURL(in: message.text)
    }

    /// The "Incoming call"/"Outgoing call" system notices from purple-teams
    /// have no link; joining goes through the plugin's /call resolution.
    private var isJoinableCallEvent: Bool {
        contact?.accountProtocol == .teams && TeamsCallLink.isCallEventMessage(message.text)
    }

    /// A protocol notice renders as a centered system line, like the day
    /// separator, with no sender attribution.
    private var systemEventView: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                RichMessageView(rawText: message.text, isFromMe: false)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(message.timestamp, style: .time)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            if let url = meetingURL {
                Button(action: { TeamsCallWindowController.shared.open(url: url) }) {
                    Label(t("Join the video call"), systemImage: "video.fill")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(t("Open the Teams call inside Adium"))
            } else if isJoinableCallEvent, let contact {
                Button(action: { PurpleBridgeService.shared.startTeamsCall(for: contact) }) {
                    Label(t("Join the call"), systemImage: "phone.arrow.down.left.fill")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(t("Open the Teams call inside Adium"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }

    var body: some View {
        if message.isSystemEvent {
            systemEventView
        } else {
            regularBubble
        }
    }

    private var regularBubble: some View {
        HStack {
            if message.isFromMe { Spacer() }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if isGroupChat && !message.isFromMe,
                   let senderName = PurpleBridgeService.shared.resolveSenderDisplayName(message.senderName, in: contact) {
                    Text(senderName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                if let imageData = message.imageData {
                    AnimatedImageView(data: imageData)
                        .frame(maxWidth: 300, maxHeight: 300)
                        .cornerRadius(8)
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

                if let url = meetingURL {
                    Button(action: { TeamsCallWindowController.shared.open(url: url) }) {
                        Label(t("Join the video call"), systemImage: "video.fill")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(t("Open the Teams call inside Adium"))
                } else if isJoinableCallEvent, let contact {
                    Button(action: { PurpleBridgeService.shared.startTeamsCall(for: contact) }) {
                        Label(t("Join the call"), systemImage: "phone.arrow.down.left.fill")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(t("Open the Teams call inside Adium"))
                }

                Text(message.timestamp, style: .time)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }

            if !message.isFromMe { Spacer() }
        }
    }
}
