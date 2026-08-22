import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct ContactListView: View {
    @Bindable var bridge = PurpleBridgeService.shared
    @AppStorage("showOfflineContacts") private var showOfflineContacts: Bool = true
    @AppStorage("contactSortOrder") private var sortOrderRaw: String = ContactSortOrder.name.rawValue
    @AppStorage("contactGroupingMode") private var groupingRaw: String = ContactGroupingMode.manual.rawValue
    
    @State private var searchText = ""
    @State private var showAddAccountSheet = false
    @State private var showCreateGroupSheet = false
    @State private var groupToRename: String? = nil
    @State private var contactToRename: Contact? = nil
    @State private var contactToCombine: Contact? = nil
    @State private var isEditingStatusMessage = false
    @State private var statusMessageDraft = ""
    @State private var collapsedDerivedSections: Set<String> = []
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isStatusMessageFocused: Bool
    
    @Binding var selectedContactID: UUID?
    
    var sortOrder: ContactSortOrder {
        ContactSortOrder(rawValue: sortOrderRaw) ?? .name
    }

    var groupingMode: ContactGroupingMode {
        ContactGroupingMode(rawValue: groupingRaw) ?? .manual
    }
    
    public init(selectedContactID: Binding<UUID?> = .constant(nil)) {
        self._selectedContactID = selectedContactID
    }
    
    public init(selectedContact: Binding<Contact?>) {
        self._selectedContactID = Binding(
            get: { selectedContact.wrappedValue?.id },
            set: { newID in
                if let newID = newID {
                    selectedContact.wrappedValue = PurpleBridgeService.shared.contacts.first(where: { $0.id == newID })
                } else {
                    selectedContact.wrappedValue = nil
                }
            }
        )
    }
    
    // This structure represents items to render per group.
    struct GroupSectionData {
        let group: ContactGroup
        let items: [DisplayItem]
        let onlineCount: Int
        let totalCount: Int
        let isExpanded: Bool
    }
    
    enum DisplayItem: Identifiable {
        case contact(Contact)
        case metacontact(Metacontact, [Contact])
        
        var id: UUID {
            switch self {
            case .contact(let c): return c.id
            case .metacontact(let m, _): return m.id
            }
        }
    }
    
    private func contactMatchesFilter(_ contact: Contact) -> Bool {
        let matchesSearch = searchText.isEmpty ||
            contact.displayName.localizedCaseInsensitiveContains(searchText) ||
            contact.name.localizedCaseInsensitiveContains(searchText) ||
            contact.handle.localizedCaseInsensitiveContains(searchText) ||
            (contact.alias?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            (contact.customStatusMessage?.localizedCaseInsensitiveContains(searchText) ?? false)

        let matchesStatus = showOfflineContacts || contact.status != .offline
        return matchesSearch && matchesStatus
    }

    private var hasActiveFilters: Bool {
        !searchText.isEmpty || !showOfflineContacts
    }

    var groupSections: [GroupSectionData] {
        switch groupingMode {
        case .manual:
            return manualGroupSections()
        case .provider, .account:
            return derivedGroupSections()
        }
    }

    /// This sorts display items with the active sort order.
    private func sortedDisplayItems(_ items: [DisplayItem]) -> [DisplayItem] {
        items.sorted { item1, item2 in
            switch (item1, item2) {
            case (.contact(let c1), .contact(let c2)):
                return compareContacts(c1, c2, order: sortOrder)
            case (.contact(let c1), .metacontact(let m2, let sc2)):
                let c2 = sc2.first ?? Contact(name: m2.name, handle: "", status: .offline)
                return compareContacts(c1, c2, order: sortOrder)
            case (.metacontact(let m1, let sc1), .contact(let c2)):
                let c1 = sc1.first ?? Contact(name: m1.name, handle: "", status: .offline)
                return compareContacts(c1, c2, order: sortOrder)
            case (.metacontact(let m1, let sc1), .metacontact(let m2, let sc2)):
                let c1 = sc1.first ?? Contact(name: m1.name, handle: "", status: .offline)
                let c2 = sc2.first ?? Contact(name: m2.name, handle: "", status: .offline)
                return compareContacts(c1, c2, order: sortOrder)
            }
        }
    }

    /// Sections follow the user-managed groups.
    private func manualGroupSections() -> [GroupSectionData] {
        var allGroupNames = bridge.contactGroups.map { $0.name }
        for c in bridge.contacts {
            if !allGroupNames.contains(c.group) {
                allGroupNames.append(c.group)
            }
        }

        // Metacontact membership spans groups.
        // A contact keeps its own group.
        // It only renders as part of the metacontact row.
        // It does not render standalone in a group section.
        var membersByMetacontactID: [UUID: [Contact]] = [:]
        for c in bridge.contacts {
            if let metaID = c.metacontactID {
                membersByMetacontactID[metaID, default: []].append(c)
            }
        }
        let allMetaMemberIDs = Set(membersByMetacontactID.values.flatMap { $0.map(\.id) })

        return allGroupNames.compactMap { groupName -> GroupSectionData? in
            let groupObj = bridge.contactGroups.first(where: { $0.name == groupName }) ?? ContactGroup(name: groupName)

            let groupContacts = bridge.contacts.filter { $0.group == groupName }
            let filteredContacts = groupContacts.filter(contactMatchesFilter)

            let onlineCount = groupContacts.filter({ $0.status != .offline }).count
            let totalCount = groupContacts.count

            var items: [DisplayItem] = []

            let groupMetacontacts = bridge.metacontacts.filter { meta in
                guard let members = membersByMetacontactID[meta.id], !members.isEmpty else { return false }
                let primary = primaryContact(for: meta, in: members)
                return primary?.group == groupName
            }
            for meta in groupMetacontacts {
                let members = membersByMetacontactID[meta.id] ?? []
                let subContacts = members.filter(contactMatchesFilter)
                if !subContacts.isEmpty {
                    items.append(.metacontact(meta, subContacts))
                }
            }

            let standalone = filteredContacts.filter { !allMetaMemberIDs.contains($0.id) }
            for c in standalone {
                items.append(.contact(c))
            }

            // This hides the section when it is empty after filtering.
            // This shows the section when it is a new empty group without filters active.
            if items.isEmpty && (hasActiveFilters || !groupContacts.isEmpty) {
                return nil
            }

            return GroupSectionData(group: groupObj, items: sortedDisplayItems(items), onlineCount: onlineCount, totalCount: totalCount, isExpanded: groupObj.isExpanded)
        }
    }

    /// The section key of a contact under the derived grouping modes.
    private func sectionKey(for c: Contact) -> String {
        switch groupingMode {
        case .manual:
            return c.group
        case .provider:
            return c.accountProtocol.rawValue
        case .account:
            let owner = c.accountUsername?.isEmpty == false ? c.accountUsername! : t("Unknown Account")
            return "\(c.accountProtocol.rawValue) · \(owner)"
        }
    }

    /// Provider and account modes derive sections from the contacts.
    /// A metacontact renders in the section of its primary contact.
    private func derivedGroupSections() -> [GroupSectionData] {
        var membersByMetacontactID: [UUID: [Contact]] = [:]
        for c in bridge.contacts {
            if let metaID = c.metacontactID {
                membersByMetacontactID[metaID, default: []].append(c)
            }
        }
        let allMetaMemberIDs = Set(membersByMetacontactID.values.flatMap { $0.map(\.id) })

        var order: [String] = []
        var itemsByKey: [String: [DisplayItem]] = [:]
        var statsByKey: [String: (online: Int, total: Int)] = [:]
        func ensureKey(_ key: String) {
            if itemsByKey[key] == nil {
                itemsByKey[key] = []
                order.append(key)
            }
        }

        for meta in bridge.metacontacts {
            guard let members = membersByMetacontactID[meta.id], !members.isEmpty,
                  let primary = primaryContact(for: meta, in: members) else { continue }
            let subContacts = members.filter(contactMatchesFilter)
            guard !subContacts.isEmpty else { continue }
            let key = sectionKey(for: primary)
            ensureKey(key)
            itemsByKey[key]?.append(.metacontact(meta, subContacts))
        }
        for c in bridge.contacts where contactMatchesFilter(c) && !allMetaMemberIDs.contains(c.id) {
            let key = sectionKey(for: c)
            ensureKey(key)
            itemsByKey[key]?.append(.contact(c))
        }
        for c in bridge.contacts {
            let key = sectionKey(for: c)
            ensureKey(key)
            let s = statsByKey[key] ?? (0, 0)
            statsByKey[key] = (online: s.online + (c.status != .offline ? 1 : 0), total: s.total + 1)
        }

        return order.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.compactMap { key in
            let items = itemsByKey[key] ?? []
            // An empty result means every contact was filtered out.
            if items.isEmpty && hasActiveFilters {
                return nil
            }
            let stats = statsByKey[key] ?? (0, 0)
            return GroupSectionData(
                group: ContactGroup(name: key),
                items: sortedDisplayItems(items),
                onlineCount: stats.online,
                totalCount: stats.total,
                isExpanded: !collapsedDerivedSections.contains(key)
            )
        }
    }
    
    private func primaryContact(for meta: Metacontact, in members: [Contact]) -> Contact? {
        if let pID = meta.primaryContactID, let found = members.first(where: { $0.id == pID }) {
            return found
        }
        return members.first
    }

    func compareContacts(_ c1: Contact, _ c2: Contact, order: ContactSortOrder) -> Bool {
        switch order {
        case .name:
            return c1.displayName.localizedCaseInsensitiveCompare(c2.displayName) == .orderedAscending
        case .status:
            if c1.status.sortPriority != c2.status.sortPriority {
                return c1.status.sortPriority < c2.status.sortPriority
            }
            return c1.displayName.localizedCaseInsensitiveCompare(c2.displayName) == .orderedAscending
        case .byActivity:
            // Unread conversations always sort first, then by last message.
            let unread1 = bridge.unreadCounts[c1.id, default: 0]
            let unread2 = bridge.unreadCounts[c2.id, default: 0]
            if unread1 != unread2 {
                return unread1 > unread2
            }
            let d1 = bridge.lastActivityDates[c1.id] ?? .distantPast
            let d2 = bridge.lastActivityDates[c2.id] ?? .distantPast
            if d1 != d2 {
                return d1 > d2
            }
            return c1.displayName.localizedCaseInsensitiveCompare(c2.displayName) == .orderedAscending
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(bridge.myStatus))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                
                Menu {
                    ForEach(OnlineStatus.allCases, id: \.self) { status in
                        Button(action: { bridge.setUserStatus(status) }) {
                            Label(statusLabel(status), systemImage: status.iconName)
                        }
                    }
                } label: {
                    Text(statusLabel(bridge.myStatus))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .menuStyle(.borderlessButton)

                Spacer()
                
                Menu {
                    Toggle(t("Show Offline Contacts"), isOn: $showOfflineContacts)
                    Divider()
                    Picker(t("Sort Order"), selection: $sortOrderRaw) {
                        ForEach(ContactSortOrder.allCases, id: \.rawValue) { sort in
                            Text(sort.displayName).tag(sort.rawValue)
                        }
                    }
                    Divider()
                    Picker(t("Group By"), selection: $groupingRaw) {
                        ForEach(ContactGroupingMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .help(t("Filter and Sort"))
                .accessibilityLabel(t("Filter and Sort"))
                
                Button(action: { showCreateGroupSheet = true }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(t("Create new group"))
                .accessibilityLabel(t("Create new group"))
                
                Button(action: { TranscriptViewerWindowController.shared.show() }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(t("Open transcript and history viewer (⌘⌥T / ⌘⇧T)"))
                .accessibilityLabel(t("Open transcript viewer"))
                
                Button(action: { FileTransferWindowController.shared.show() }) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(t("File transfers (⌘⌥L)"))
                .accessibilityLabel(t("File transfers"))
                
                Button(action: { showAddAccountSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .help(t("Add new account (⌘⇧A)"))
                .accessibilityLabel(t("Add Account"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Material.bar)

            HStack(spacing: 4) {
                if isEditingStatusMessage {
                    TextField(t("Status message…"), text: $statusMessageDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .focused($isStatusMessageFocused)
                        .onSubmit { commitStatusMessage() }
                        .onAppear { isStatusMessageFocused = true }

                    Button(action: commitStatusMessage) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help(t("Save status message"))
                    .accessibilityLabel(t("Save status message"))
                } else {
                    Button(action: {
                        statusMessageDraft = bridge.myStatusMessage
                        isEditingStatusMessage = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 8))
                            Text(bridge.myStatusMessage.isEmpty ? t("Add status message…") : bridge.myStatusMessage)
                                .font(.system(size: 9.5))
                                .lineLimit(1)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(t("Set a custom status message"))

                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
            .background(Material.bar)

            Divider()

            if bridge.hasAccountError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 10))
                        .accessibilityHidden(true)

                    Text(bridge.accountErrorSummary ?? t("Connection error"))
                        .font(.system(size: 9))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button(t("Reconnect")) {
                        bridge.reconnectAccounts()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.system(size: 9, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.15))
                
                Divider()
            }
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                TextField(t("Search contacts..."), text: $searchText)
                    .focused($isSearchFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("Clear search"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .onReceive(NotificationCenter.default.publisher(for: .focusContactSearch)) { _ in
                isSearchFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openNewConversation)) { _ in
                isSearchFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openAddAccount)) { _ in
                showAddAccountSheet = true
            }
            
            Divider()
            
            if bridge.accounts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 36))
                        .foregroundColor(.accentColor)
                        .accessibilityHidden(true)

                    Text(t("No Accounts Configured"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text(t("Add your Microsoft Teams, WhatsApp, or XMPP account to load your contacts and start chatting."))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    Button(action: { showAddAccountSheet = true }) {
                        Label(t("Add Account"), systemImage: "plus.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bridge.contacts.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    
                    Text(bridge.hasAccountError ? t("Error connecting account") : t("Connecting account..."))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text(t("Connected to \(bridge.accounts.first?.username ?? ""). Waiting for libpurple events..."))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    HStack(spacing: 8) {
                        Button(t("Reconnect")) {
                            bridge.reconnectAccounts()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        
                        Button(t("Manage Accounts")) {
                            showAddAccountSheet = true
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                    }
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedContactID) {
                    ForEach(groupSections, id: \.group.name) { section in
                        Section(header: GroupHeaderView(
                            group: section.group,
                            onlineCount: section.onlineCount,
                            totalCount: section.totalCount,
                            isExpanded: section.isExpanded,
                            onToggle: {
                                if groupingMode == .manual {
                                    bridge.toggleGroupExpanded(name: section.group.name)
                                } else {
                                    if collapsedDerivedSections.contains(section.group.name) {
                                        collapsedDerivedSections.remove(section.group.name)
                                    } else {
                                        collapsedDerivedSections.insert(section.group.name)
                                    }
                                }
                            },
                            onRename: groupingMode == .manual ? { groupToRename = section.group.name } : nil,
                            onDelete: groupingMode == .manual ? { bridge.deleteGroup(name: section.group.name) } : nil
                        )) {
                            if section.isExpanded {
                                ForEach(section.items) { item in
                                    switch item {
                                    case .contact(let contact):
                                        ContactRowView(
                                            contact: contact,
                                            onRename: { contactToRename = contact },
                                            onCombine: { contactToCombine = contact },
                                            onSelectAvatar: { selectAvatarForContact(contact) }
                                        )
                                        .tag(contact.id)
                                    case .metacontact(let meta, let subContacts):
                                        MetacontactRowView(
                                            metacontact: meta,
                                            subContacts: subContacts,
                                            selectedContactID: $selectedContactID
                                        )
                                        .tag(primaryContact(for: meta, in: subContacts)?.id ?? meta.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .task(id: sortOrderRaw) {
                    // The By Activity order needs last message dates.
                    if sortOrder == .byActivity {
                        bridge.hydrateLastActivityDates()
                    }
                }
            }
            
            Divider()
            
            HStack(spacing: 6) {
                Circle()
                    .fill(bridge.hasAccountError ? Color.red : (bridge.isLibpurpleLoaded ? Color.green : Color.orange))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(bridge.connectionState)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                if bridge.accounts.contains(where: { !$0.isConnected }) {
                    Button(action: { bridge.reconnectAccounts() }) {
                        Label(t("Reconnect"), systemImage: "arrow.clockwise")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .help(t("Reconnect disconnected accounts"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Material.bar)
        }
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 320, minHeight: 380, idealHeight: 550)
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(isPresented: $showAddAccountSheet)
        }
        .sheet(isPresented: $showCreateGroupSheet) {
            CreateGroupSheet(isPresented: $showCreateGroupSheet)
        }
        .sheet(item: Binding(get: { groupToRename.map { GroupRenameWrapper(name: $0) } }, set: { groupToRename = $0?.name })) { wrapper in
            RenameGroupSheet(groupName: wrapper.name, isPresented: Binding(get: { groupToRename != nil }, set: { if !$0 { groupToRename = nil } }))
        }
        .sheet(item: $contactToRename) { contact in
            SetAliasSheet(contact: contact, isPresented: Binding(get: { contactToRename != nil }, set: { if !$0 { contactToRename = nil } }))
        }
        .sheet(item: $contactToCombine) { contact in
            CombineContactsSheet(sourceContact: contact, isPresented: Binding(get: { contactToCombine != nil }, set: { if !$0 { contactToCombine = nil } }))
        }
    }
    
    private func selectAvatarForContact(_ contact: Contact) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            bridge.setAvatar(data: data, for: contact.id)
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

    private func commitStatusMessage() {
        bridge.setStatusMessage(statusMessageDraft)
        isEditingStatusMessage = false
    }
}

// This struct wraps the sheet item binding.
struct GroupRenameWrapper: Identifiable {
    var id: String { name }
    let name: String
}

// MARK: - Subviews & Rows

struct GroupHeaderView: View {
    let group: ContactGroup
    let onlineCount: Int
    let totalCount: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    // Derived sections (provider/account) have no stored group, so the
    // rename and delete actions only exist for manual groups.
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    @Bindable var bridge = PurpleBridgeService.shared

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { onToggle() }) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? t("Collapse group") : t("Expand group"))

            Text(group.name)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.primary)

            Spacer()

            Text("\(onlineCount)/\(totalCount)")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let onRename {
                Button(t("Rename Group...")) {
                    onRename()
                }
            }
            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(t("Delete Group"), systemImage: "trash")
                }
            }
        }
    }
}

struct ContactAvatarView: View {
    let name: String
    let avatarData: Data?
    let status: OnlineStatus
    let isBlocked: Bool
    var size: CGFloat = 26

    var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2, let first = parts.first?.first, let last = parts.last?.first {
            return "\(first)\(last)".uppercased()
        } else if let first = name.first {
            return String(first).uppercased()
        }
        return "?"
    }

    var avatarGradient: LinearGradient {
        let hash = abs(name.hashValue)
        let colors: [[Color]] = [
            [.blue, .purple],
            [.teal, .blue],
            [.indigo, .cyan],
            [.orange, .red],
            [.pink, .purple],
            [.mint, .teal]
        ]
        let pair = colors[hash % colors.count]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let data = avatarData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundColor(.white)
                    )
            }

            if isBlocked {
                Image(systemName: "slash.circle.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundColor(.red)
                    .background(Circle().fill(Color.white))
                    .accessibilityLabel(t("Blocked"))
            } else {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: size * 0.32, height: size * 0.32)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .accessibilityLabel(t("Status: \(status.rawValue)"))
            }
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

struct ContactRowView: View {
    let contact: Contact
    let onRename: () -> Void
    let onCombine: () -> Void
    let onSelectAvatar: () -> Void
    @Bindable var bridge = PurpleBridgeService.shared
    
    var body: some View {
        HStack(spacing: 8) {
            ContactAvatarView(
                name: contact.displayName,
                avatarData: contact.avatarData,
                status: contact.status,
                isBlocked: contact.isBlocked,
                size: 26
            )
            
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(contact.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(contact.isBlocked ? .secondary : .primary)
                        .strikethrough(contact.isBlocked, color: .secondary)
                        .lineLimit(1)
                    
                    if contact.alias != nil {
                        Image(systemName: "pencil")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .accessibilityHidden(true)
                    }

                    Spacer()

                    Image(systemName: contact.accountProtocol.iconName)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .accessibilityLabel(contact.accountProtocol.rawValue)
                }
                
                if let msg = contact.customStatusMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(contact.handle)
                        .font(.system(size: 8.5))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }

                // With two or more accounts on one protocol the row needs
                // to say which account owns this contact.
                if showAccountHint {
                    Text(contact.accountUsername ?? "")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(t("Rename / Set Alias...")) {
                onRename()
            }
            if contact.alias != nil {
                Button(t("Remove Alias")) {
                    bridge.setAlias(nil, for: contact.id)
                }
            }

            Button(t("Change Icon / Avatar...")) {
                onSelectAvatar()
            }

            Divider()

            Button(t("Combine into Metacontact...")) {
                onCombine()
            }

            Menu(t("Move to Group")) {
                ForEach(bridge.contactGroups, id: \.id) { group in
                    Button(group.name) {
                        bridge.moveContact(contact.id, toGroup: group.name)
                    }
                }
            }
            
            Divider()
            
            Button(contact.isBlocked ? t("Unblock Contact") : t("Block Contact")) {
                bridge.toggleBlockContact(contact.id)
            }

            Divider()

            Button(contact.isMuted ? t("Unmute Notifications") : t("Mute Notifications")) {
                bridge.setMuted(!contact.isMuted, for: contact.id)
            }
        }
        .help(showAccountHint ? "\(contact.displayName) · \(contact.accountUsername ?? "")" : "")
    }

    /// True when another account shares this contact's protocol.
    private var showAccountHint: Bool {
        guard let account = contact.accountUsername, !account.isEmpty else { return false }
        return bridge.accounts.filter { $0.accountProtocol == contact.accountProtocol }.count > 1
    }
}

struct MetacontactRowView: View {
    let metacontact: Metacontact
    let subContacts: [Contact]
    @Binding var selectedContactID: UUID?
    @State private var isExpanded: Bool = false
    @Bindable var bridge = PurpleBridgeService.shared
    
    var primaryContact: Contact? {
        if let pID = metacontact.primaryContactID, let found = subContacts.first(where: { $0.id == pID }) {
            return found
        }
        return subContacts.first
    }
    
    var highestStatus: OnlineStatus {
        if subContacts.contains(where: { $0.status == .available }) { return .available }
        if subContacts.contains(where: { $0.status == .away }) { return .away }
        if subContacts.contains(where: { $0.status == .busy }) { return .busy }
        return .offline
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { withAnimation { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? t("Collapse metacontact") : t("Expand metacontact"))
                
                ContactAvatarView(
                    name: metacontact.name,
                    avatarData: metacontact.avatarData ?? primaryContact?.avatarData,
                    status: highestStatus,
                    isBlocked: false,
                    size: 26
                )
                
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(metacontact.name)
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                        
                        Label(t("Metacontact"), systemImage: "person.2.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 9))
                            .foregroundColor(.accentColor)
                        
                        Spacer()
                        
                        // The caption below states the same protocols, so hide this row from accessibility.
                        HStack(spacing: 2) {
                            ForEach(subContacts, id: \.id) { sc in
                                Image(systemName: sc.accountProtocol.iconName)
                                    .font(.system(size: 8))
                                    .foregroundColor(sc.id == primaryContact?.id ? .accentColor : .secondary)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    
                    Text(t("\(subContacts.count) combined accounts (\(primaryContact?.accountProtocol.rawValue ?? ""))"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .contextMenu {
                Menu(t("Set Primary Account")) {
                    ForEach(subContacts, id: \.id) { sc in
                        Button("\(sc.displayName) (\(sc.accountProtocol.rawValue))") {
                            bridge.setPrimaryContact(contactID: sc.id, inMetacontact: metacontact.id)
                        }
                    }
                }
                
                Button(role: .destructive) {
                    bridge.unlinkMetacontact(metacontact.id)
                } label: {
                    Label(t("Unlink Metacontact"), systemImage: "link.badge.plus")
                }
            }
            
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(subContacts, id: \.id) { sc in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(sc.id == primaryContact?.id ? Color.accentColor : Color.clear)
                                .frame(width: 4, height: 4)
                                .accessibilityHidden(true)

                            Image(systemName: sc.accountProtocol.iconName)
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                                .accessibilityLabel(sc.accountProtocol.rawValue)
                            
                            Text(sc.displayName)
                                .font(.system(size: 10, weight: sc.id == primaryContact?.id ? .semibold : .regular))
                            
                            Spacer()
                            
                            Text(sc.status.rawValue)
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 28)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedContactID = sc.id
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Context Sheets

struct CreateGroupSheet: View {
    @Binding var isPresented: Bool
    @State private var groupName = ""
    @Bindable var bridge = PurpleBridgeService.shared
    
    var body: some View {
        VStack(spacing: 12) {
            Text(t("Create New Group"))
                .font(.system(size: 13, weight: .bold))

            TextField(t("Group name:"), text: $groupName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            
            HStack {
                Button(t("Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Create")) {
                    bridge.createGroup(name: groupName)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

struct RenameGroupSheet: View {
    let groupName: String
    @Binding var isPresented: Bool
    @State private var newName = ""
    @Bindable var bridge = PurpleBridgeService.shared

    private var trimmedNewName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Consistent with createGroup's own duplicate check (case-insensitive),
    // excluding the group being renamed itself.
    private var isDuplicateName: Bool {
        let trimmed = trimmedNewName
        guard !trimmed.isEmpty else { return false }
        return bridge.contactGroups.contains { group in
            group.name != groupName && group.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(t("Rename Group '\(groupName)'"))
                .font(.system(size: 13, weight: .bold))

            TextField(t("New name:"), text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onAppear { newName = groupName }

            if isDuplicateName {
                Text(t("A group with that name already exists."))
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }

            HStack {
                Button(t("Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Save")) {
                    if trimmedNewName != groupName {
                        bridge.renameGroup(oldName: groupName, newName: trimmedNewName)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedNewName.isEmpty || isDuplicateName)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

struct SetAliasSheet: View {
    let contact: Contact
    @Binding var isPresented: Bool
    @State private var aliasText = ""
    @Bindable var bridge = PurpleBridgeService.shared
    
    var body: some View {
        VStack(spacing: 12) {
            Text(t("Rename Contact (Local Alias)"))
                .font(.system(size: 13, weight: .bold))

            Text(t("Set an alias for '\(contact.name)' visible only in your list."))
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            TextField(t("Alias:"), text: $aliasText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onAppear { aliasText = contact.alias ?? contact.name }
            
            HStack {
                Button(t("Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Save")) {
                    bridge.setAlias(aliasText, for: contact.id)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct CombineContactsSheet: View {
    let sourceContact: Contact
    @Binding var isPresented: Bool
    @State private var selectedTargetID: UUID?
    @State private var metacontactName = ""
    @Bindable var bridge = PurpleBridgeService.shared
    
    var availableTargets: [Contact] {
        bridge.contacts.filter { $0.id != sourceContact.id }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text(t("Combine into Metacontact"))
                .font(.system(size: 13, weight: .bold))

            Text(t("Select another contact to merge their accounts into a single metacontact entry."))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Form {
                TextField(t("Metacontact name:"), text: $metacontactName)
                    .font(.system(size: 11))
                    .onAppear { metacontactName = sourceContact.displayName }

                Picker(t("Combine with:"), selection: $selectedTargetID) {
                    Text(t("Select a contact...")).tag(UUID?.none)
                    ForEach(availableTargets, id: \.id) { target in
                        Text("\(target.displayName) (\(target.accountProtocol.rawValue))").tag(UUID?.some(target.id))
                    }
                }
                .font(.system(size: 11))
            }
            .formStyle(.grouped)
            
            HStack {
                Button(t("Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Combine")) {
                    if let targetID = selectedTargetID {
                        bridge.combineContacts([sourceContact.id, targetID], name: metacontactName)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedTargetID == nil)
            }
        }
        .padding(16)
        .frame(width: 360, height: 260)
    }
}
