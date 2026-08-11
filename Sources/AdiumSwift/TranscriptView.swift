import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct HighlightedText: View {
    let text: String
    let highlight: String
    
    public init(text: String, highlight: String) {
        self.text = text
        self.highlight = highlight
    }
    
    public var body: some View {
        if highlight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(text)
        } else {
            Text(attributedString)
        }
    }
    
    private var attributedString: AttributedString {
        var attributed = AttributedString(text)
        let trimmedHighlight = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHighlight.isEmpty else { return attributed }
        
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: trimmedHighlight, options: .caseInsensitive, range: searchRange) {
            if let attrRange = Range(range, in: attributed) {
                attributed[attrRange].backgroundColor = Color.yellow.opacity(0.4)
                attributed[attrRange].inlinePresentationIntent = .stronglyEmphasized
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return attributed
    }
}

public struct TranscriptView: View {
    @Bindable var bridge = PurpleBridgeService.shared
    @Bindable var store = ChatLogStore.shared
    
    @State private var searchText: String = ""
    @State private var selectedContactHandle: String = "ALL"
    @State private var selectedProtocolRaw: String = "ALL"
    @State private var useDateFilter: Bool = false
    @State private var startDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate: Date = Date()
    
    @State private var selectedHandle: String?
    @State private var exportFormat: TranscriptExportFormat = .plainText
    @State private var exportStatusMessage: String?
    @State private var handleToDelete: String?
    
    public init() {}
    
    var selectedProtocol: AccountProtocol? {
        AccountProtocol(rawValue: selectedProtocolRaw)
    }
    
    var availableHandles: [String] {
        store.allLogHandles()
    }
    
    var filteredResults: [(handle: String, messages: [ChatMessage])] {
        let results = store.filterMessages(
            contactHandle: selectedContactHandle == "ALL" ? nil : selectedContactHandle,
            protocolType: selectedProtocol,
            startDate: useDateFilter ? startDate : nil,
            endDate: useDateFilter ? endDate : nil,
            searchText: searchText,
            contacts: bridge.contacts
        )
        return results
    }
    
    var currentHandleMessages: [ChatMessage] {
        guard let handle = selectedHandle ?? filteredResults.first?.handle else { return [] }
        // Only show messages that pass the active filters. Never show the
        // unfiltered log for a handle that the filters exclude.
        return filteredResults.first(where: { $0.handle == handle })?.messages ?? []
    }
    
    var currentContact: Contact? {
        guard let handle = selectedHandle ?? filteredResults.first?.handle else { return nil }
        return bridge.contacts.first(where: { store.sanitizeHandle($0.handle) == handle || $0.handle.caseInsensitiveCompare(handle) == .orderedSame })
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header / Search & Filter Controls
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)

                    TextField(t("Search the full transcript history..."), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))

                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t("Clear search"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                
                // Filters Row
                HStack(spacing: 12) {
                    // Contact Filter
                    HStack(spacing: 4) {
                        Text(t("Contact:"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Picker("", selection: $selectedContactHandle) {
                            Text(t("All contacts")).tag("ALL")
                            ForEach(availableHandles, id: \.self) { handle in
                                let display = bridge.contacts.first(where: { store.sanitizeHandle($0.handle) == handle })?.displayName ?? handle
                                Text(display).tag(handle)
                            }
                        }
                        .labelsHidden()
                        .font(.system(size: 10))
                        .frame(maxWidth: 160)
                    }
                    
                    // Protocol Filter
                    HStack(spacing: 4) {
                        Text(t("Protocol:"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Picker("", selection: $selectedProtocolRaw) {
                            Text(t("All protocols")).tag("ALL")
                            ForEach(AccountProtocol.allCases, id: \.rawValue) { proto in
                                Text(proto.rawValue).tag(proto.rawValue)
                            }
                        }
                        .labelsHidden()
                        .font(.system(size: 10))
                        .frame(maxWidth: 160)
                    }
                    
                    // Date Filter Toggle
                    Toggle(t("Filter by Date"), isOn: $useDateFilter)
                        .font(.system(size: 10, weight: .medium))
                    
                    if useDateFilter {
                        DatePicker("", selection: $startDate, displayedComponents: .date)
                            .labelsHidden()
                            .font(.system(size: 10))
                        Text(t("to"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        DatePicker("", selection: $endDate, displayedComponents: .date)
                            .labelsHidden()
                            .font(.system(size: 10))
                    }
                    
                    Spacer()
                }
            }
            .padding(12)
            .background(Material.bar)
            
            Divider()
            
            // Main Content Area
            if filteredResults.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text(t("No transcripts match the filters."))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Left Sidebar: Conversations that match the filters
                    List(filteredResults, id: \.handle, selection: $selectedHandle) { result in
                        let contact = bridge.contacts.first(where: { store.sanitizeHandle($0.handle) == result.handle || $0.handle.caseInsensitiveCompare(result.handle) == .orderedSame })
                        let displayName = contact?.displayName ?? result.handle
                        let proto = contact?.accountProtocol
                        
                        HStack(spacing: 8) {
                            Image(systemName: proto?.iconName ?? "bubble.left.and.bubble.right")
                                .foregroundColor(.accentColor)
                                .font(.system(size: 12))
                                .accessibilityHidden(true)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                HStack {
                                    Text("\(result.messages.count) msgs")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    if let last = result.messages.last {
                                        Text("• \(last.timestamp, style: .date)")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Spacer()
                        }
                        .tag(result.handle)
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button(role: .destructive) {
                                handleToDelete = result.handle
                            } label: {
                                Label(t("Delete Transcript"), systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                    
                    // Right Detail: Selected Conversation Messages
                    VStack(spacing: 0) {
                        // Toolbar for selected conversation
                        if let activeHandle = selectedHandle ?? filteredResults.first?.handle {
                            let contact = currentContact
                            let displayName = contact?.displayName ?? activeHandle
                            let proto = contact?.accountProtocol
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(displayName)
                                        .font(.system(size: 12, weight: .bold))
                                    Text("Handle: \(activeHandle)" + (proto != nil ? " • \(proto!.rawValue)" : ""))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Picker(t("Format:"), selection: $exportFormat) {
                                    ForEach(TranscriptExportFormat.allCases) { format in
                                        Text(format.displayName).tag(format)
                                    }
                                }
                                .frame(width: 140)
                                .font(.system(size: 10))
                                
                                Button(action: {
                                    exportCurrentChat(handle: activeHandle, displayName: displayName, protocolType: proto)
                                }) {
                                    Label(t("Export Chat"), systemImage: "square.and.arrow.up")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(.borderedProminent)

                                Button(action: {
                                    handleToDelete = activeHandle
                                }) {
                                    Label(t("Delete"), systemImage: "trash")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .help(t("Permanently delete this transcript"))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            
                            Divider()
                            
                            // Message stream list
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(currentHandleMessages) { msg in
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(msg.isFromMe ? t("Me") : msg.senderName)
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(msg.isFromMe ? .accentColor : .primary)
                                                Spacer()
                                                Text(msg.timestamp, style: .date)
                                                    .font(.system(size: 8))
                                                    .foregroundColor(.secondary)
                                                Text(msg.timestamp, style: .time)
                                                    .font(.system(size: 8))
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            HighlightedText(text: msg.text, highlight: searchText)
                                                .font(.system(size: 11))
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(msg.isFromMe ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                                                )
                                        }
                                        .padding(.horizontal, 12)
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                        } else {
                            ContentUnavailableView(t("Select a chat"), systemImage: "message")
                        }
                    }
                }
            }
            
            if let status = exportStatusMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .accessibilityHidden(true)
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 750, minHeight: 480)
        .onAppear {
            if selectedHandle == nil, let first = filteredResults.first {
                selectedHandle = first.handle
            }
        }
        .onChange(of: filteredResults.map(\.handle)) { _, handles in
            // If the filters remove the selected conversation, clear the selection.
            // Do not show its unfiltered history.
            if let handle = selectedHandle, !handles.contains(handle) {
                selectedHandle = handles.first
            }
        }
        .alert(
            t("Delete transcript?"),
            isPresented: Binding(
                get: { handleToDelete != nil },
                set: { if !$0 { handleToDelete = nil } }
            ),
            presenting: handleToDelete
        ) { handle in
            Button(t("Cancel"), role: .cancel) {}
            Button(t("Delete"), role: .destructive) {
                deleteTranscript(handle: handle)
            }
        } message: { handle in
            let display = bridge.contacts.first(where: { store.sanitizeHandle($0.handle) == handle })?.displayName ?? handle
            Text(t("The chat history with \(display) will be deleted permanently. This action cannot be undone."))
        }
    }

    private func deleteTranscript(handle: String) {
        store.deleteLog(for: handle)
        // Clear the in-memory cache so an open chat does not re-save the log.
        if let contact = bridge.contacts.first(where: { store.sanitizeHandle($0.handle) == handle || $0.handle.caseInsensitiveCompare(handle) == .orderedSame }) {
            bridge.messagesPerContact.removeValue(forKey: contact.id)
        }
        if selectedHandle == handle {
            selectedHandle = nil
        }
    }
    
    private func exportCurrentChat(handle: String, displayName: String, protocolType: AccountProtocol?) {
        let panel = NSSavePanel()
        let safeName = store.sanitizeHandle(displayName)
        panel.nameFieldStringValue = "Chat_\(safeName).\(exportFormat.fileExtension)"
        panel.title = t("Export Chat (\(exportFormat.displayName))")
        panel.prompt = t("Save")
        
        if exportFormat == .json {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        
        panel.begin { response in
            if response == .OK, let targetURL = panel.url {
                do {
                    let msgs = currentHandleMessages
                    try store.exportTranscript(
                        messages: msgs,
                        handle: handle,
                        displayName: displayName,
                        protocolType: protocolType,
                        format: exportFormat,
                        to: targetURL
                    )
                    exportStatusMessage = t("Chat exported successfully to \(targetURL.lastPathComponent)")
                } catch {
                    exportStatusMessage = t("Failed to export chat: \(error.localizedDescription)")
                }
            }
        }
    }
}
